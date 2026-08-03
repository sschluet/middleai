import Foundation
import Security

public protocol OpenWebUIClientProtocol: Sendable {
  func authenticate() async throws
  func health() async throws
  func models() async throws -> [String]
  func createChat(title: String, messages: [Message], model: String) async throws -> String
  func send(
    messages: [Message], chatID: String, model: String,
    onToken: @escaping @Sendable (String) -> Void
  ) async throws -> String
  func cancel(chatID: String) async
  func listChats() async throws -> [(id: String, title: String)]
  func chatURL(id: String) -> URL
}

extension OpenWebUIClientProtocol {
  public func cancel(chatID: String) async {}
}

public final class OpenWebUIClient: OpenWebUIClientProtocol, @unchecked Sendable {
  private struct ModelOptions: Sendable {
    var features: [String: Bool] = [:]
    var toolIDs: [String] = []
  }

  private struct CompletionResult: Sendable {
    let text: String
    let finishReason: String?
    let requestedToolCall: Bool

    var isComplete: Bool {
      !requestedToolCall && finishReason != "length"
    }
  }

  private struct PersistedAssistant: Sendable {
    let text: String
    let done: Bool
  }

  private struct AsyncTaskResponse: Decodable, Sendable {
    let status: Bool?
    let taskIDs: [String]?

    enum CodingKeys: String, CodingKey {
      case status
      case taskIDs = "task_ids"
    }

    var accepted: Bool { status == true && !(taskIDs ?? []).isEmpty }
  }

  private struct StreamChunk: Decodable, Sendable {
    struct Choice: Decodable, Sendable {
      struct Content: Decodable, Sendable {
        struct ToolCall: Decodable, Sendable {}

        let content: String?
        let toolCalls: [ToolCall]?

        enum CodingKeys: String, CodingKey {
          case content
          case toolCalls = "tool_calls"
        }
      }

      let delta: Content?
      let message: Content?
      let finishReason: String?

      enum CodingKeys: String, CodingKey {
        case delta
        case message
        case finishReason = "finish_reason"
      }
    }

    struct EventData: Decodable, Sendable {
      let content: String?
      let done: Bool?
    }

    let choices: [Choice]?
    let data: EventData?
    let content: String?
    let done: Bool?
  }

  private enum StreamOutcome: Sendable {
    case completed(CompletionResult)
    case asynchronous
  }

  private enum StreamingFailure: Error, Sendable {
    case rejected(status: Int, detail: String?)
  }

  public let baseURL: URL
  private let auth: any AuthProvider
  private let session: URLSession
  private let lock = NSLock()
  private var bearer: String?
  private var modelOptions: [String: ModelOptions] = [:]
  public init(
    baseURL: URL, auth: any AuthProvider, tlsVerify: Bool = true, caFile: String? = nil,
    session: URLSession? = nil
  ) {
    self.baseURL = baseURL
    self.auth = auth
    if let session {
      self.session = session
    } else {
      self.session = URLSession(
        configuration: .default, delegate: TLSDelegate(verify: tlsVerify, caFile: caFile),
        delegateQueue: nil)
    }
  }
  public func authenticate() async throws {
    let value = try await auth.token(baseURL: baseURL, session: session)
    lock.clientLock { bearer = value }
  }
  public func health() async throws {
    var r = URLRequest(url: baseURL.appendingPathComponent("health"))
    r.timeoutInterval = 5
    let (_, response) = try await session.data(for: r)
    guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<500).contains(code) else {
      throw MiddleAIError.network("Open WebUI is unreachable")
    }
  }
  public func models() async throws -> [String] {
    let (data, _) = try await request(path: "api/models")
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let rows = root?["data"] as? [[String: Any]] ?? []
    let parsed = rows.reduce(into: [String: ModelOptions]()) { result, row in
      guard let id = row["id"] as? String else { return }
      result[id] = Self.options(from: row)
    }
    lock.clientLock { modelOptions = parsed }
    return rows.compactMap { $0["id"] as? String }
  }
  public func createChat(title: String, messages: [Message], model: String) async throws -> String {
    let snapshot = chatSnapshot(title: title, messages: messages, model: model)
    let (data, _) = try await request(
      path: "api/v1/chats/new", method: "POST", json: ["chat": snapshot])
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let id = (root?["id"] as? String) ?? ((root?["chat"] as? [String: Any])?["id"] as? String)
    else { throw MiddleAIError.invalidResponse("new chat has no id") }
    return id
  }
  public func send(
    messages: [Message], chatID: String, model: String,
    onToken: @escaping @Sendable (String) -> Void
  ) async throws -> String {
    guard !model.isEmpty else { throw MiddleAIError.noModel }
    let assistantID = UUID().uuidString
    let sessionID = UUID().uuidString
    let title = String(
      (messages.first(where: { $0.role == .user })?.content ?? "New Chat").prefix(80))
    let withPlaceholder = messages + [Message(id: assistantID, role: .assistant, content: "")]
    _ = try? await request(
      path: "api/v1/chats/\(chatID)", method: "POST",
      json: ["chat": chatSnapshot(title: title, messages: withPlaceholder, model: model)])
    let options = try await options(for: model)
    let features: [String: Bool] = [
      "web_search": options.features["web_search"] == true,
      "code_interpreter": options.features["code_interpreter"] == true,
      "image_generation": options.features["image_generation"] == true,
    ]
    let metadata: [String: Any] = [
      "chat_id": chatID, "message_id": assistantID, "session_id": sessionID,
      "tool_ids": options.toolIDs, "files": [], "features": features, "model": model,
    ]
    var body: [String: Any] = [
      "model": model, "messages": messages.map(messageJSON), "stream": true, "chat_id": chatID,
      "id": assistantID, "session_id": sessionID, "tool_ids": options.toolIDs, "files": [],
      "features": features, "metadata": metadata,
      "background_tasks": [
        "title_generation": false, "tags_generation": false, "follow_up_generation": false,
      ],
    ]
    let initial: CompletionResult
    do {
      switch try await stream(path: "api/chat/completions", json: body, onToken: onToken) {
      case .completed(let streamed):
        initial = try validated(streamed)
      case .asynchronous:
        let persisted = try await waitForAssistant(
          chatID: chatID, assistantID: assistantID, onToken: onToken)
        initial = CompletionResult(text: persisted, finishReason: "stop", requestedToolCall: false)
      }
    } catch let StreamingFailure.rejected(status, _) where Self.supportsNonStreamingFallback(status)
    {
      // Some OpenWebUI adapters only expose the OpenAI-compatible non-streaming response over
      // HTTP. Retrying is safe here because a rejected request did not start a generation.
      body["stream"] = false
      let data = try await request(path: "api/chat/completions", method: "POST", json: body).0
      if isAsyncTaskResponse(data) {
        let persisted = try await waitForAssistant(
          chatID: chatID, assistantID: assistantID, onToken: onToken)
        initial = CompletionResult(text: persisted, finishReason: "stop", requestedToolCall: false)
      } else {
        let completion = try validated(completionResult(from: data))
        onToken(completion.text)
        initial = completion
      }
    } catch let StreamingFailure.rejected(status, detail) {
      let suffix = detail.map { ": \($0)" } ?? ""
      throw MiddleAIError.network("OpenWebUI antwortet mit HTTP \(status)\(suffix)")
    }
    try Task.checkCancellation()
    let completed = messages + [Message(id: assistantID, role: .assistant, content: initial.text)]
    let completionBody: [String: Any] = [
      "model": model, "messages": completed.map(messageJSON), "chat_id": chatID,
      "id": assistantID, "session_id": sessionID,
      "message": ["id": assistantID, "role": "assistant", "content": initial.text],
      "tool_ids": options.toolIDs, "files": [], "features": features, "metadata": metadata,
      "background_tasks": [
        "title_generation": true, "tags_generation": false, "follow_up_generation": false,
      ],
    ]
    let finalizedData = try await request(
      path: "api/chat/completed", method: "POST", json: completionBody
    ).0
    try Task.checkCancellation()
    let finalized = completionTextIfPresent(from: finalizedData) ?? initial.text
    _ = try await request(
      path: "api/v1/chats/\(chatID)", method: "POST",
      json: [
        "chat": chatSnapshot(
          title: title,
          messages: messages + [Message(id: assistantID, role: .assistant, content: finalized)],
          model: model)
      ])
    return finalized
  }
  public func listChats() async throws -> [(id: String, title: String)] {
    let (data, _) = try await request(path: "api/v1/chats/list")
    let root = try JSONSerialization.jsonObject(with: data)
    let rows =
      (root as? [[String: Any]]) ?? ((root as? [String: Any])?["items"] as? [[String: Any]]) ?? []
    return rows.compactMap { row in
      guard let id = row["id"] as? String else { return nil }
      return (id, (row["title"] as? String) ?? "Untitled")
    }
  }
  public func cancel(chatID: String) async {
    guard !chatID.isEmpty else { return }
    _ = try? await request(path: "api/tasks/chat/\(chatID)/stop", method: "POST", json: [:])
  }
  public func chatURL(id: String) -> URL { baseURL.appendingPathComponent("c/\(id)") }

  private func authorized(_ path: String, method: String = "GET", json: [String: Any]? = nil) throws
    -> URLRequest
  {
    guard let token = lock.clientLock({ bearer }) else { throw MiddleAIError.authentication }
    var r = URLRequest(url: baseURL.appendingPathComponent(path))
    r.httpMethod = method
    r.timeoutInterval = 120
    r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let json {
      r.setValue("application/json", forHTTPHeaderField: "Content-Type")
      r.httpBody = try JSONSerialization.data(withJSONObject: json)
    }
    return r
  }
  private func request(path: String, method: String = "GET", json: [String: Any]? = nil)
    async throws -> (Data, HTTPURLResponse)
  {
    let (data, response) = try await session.data(for: authorized(path, method: method, json: json))
    guard let http = response as? HTTPURLResponse else {
      throw MiddleAIError.invalidResponse("Not HTTP")
    }
    guard (200..<300).contains(http.statusCode) else {
      let detail = responseDetail(from: data)
      let suffix = detail.map { ": \($0)" } ?? ""
      throw MiddleAIError.network("OpenWebUI antwortet mit HTTP \(http.statusCode)\(suffix)")
    }
    return (data, http)
  }
  private func responseDetail(from data: Data) -> String? {
    guard !data.isEmpty else { return nil }
    if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      for key in ["detail", "message", "error"] {
        if let value = root[key] as? String,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          return String(value.prefix(320))
        }
      }
    }
    let raw = String(decoding: data.prefix(320), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return raw.isEmpty ? nil : raw
  }
  private func completionResult(from data: Data) throws -> CompletionResult {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw MiddleAIError.invalidResponse("Chat completion is not a JSON object")
    }
    let choice = (root["choices"] as? [[String: Any]])?.first
    let message = choice?["message"] as? [String: Any]
    let candidates: [Any?] = [
      message?["content"],
      (choice?["delta"] as? [String: Any])?["content"],
      choice?["text"],
      (root["message"] as? [String: Any])?["content"],
      root["content"],
      root["response"],
    ]
    for candidate in candidates {
      if let text = textContent(candidate),
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return CompletionResult(
          text: text, finishReason: choice?["finish_reason"] as? String,
          requestedToolCall: message?["tool_calls"] is [Any]
            || (choice?["delta"] as? [String: Any])?["tool_calls"] is [Any])
      }
    }
    throw MiddleAIError.invalidResponse(
      "Chat completion contains no assistant text"
    )
  }
  private func completionTextIfPresent(from data: Data) -> String? {
    if let result = try? completionResult(from: data) { return result.text }
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    if let messages = root["messages"] as? [[String: Any]],
      let assistant = messages.reversed().first(where: { $0["role"] as? String == "assistant" })
    {
      return assistantMessageText(assistant)
    }
    if let message = root["message"] as? [String: Any] {
      return assistantMessageText(message)
    }
    return nil
  }
  private func isAsyncTaskResponse(_ data: Data) -> Bool {
    (try? JSONDecoder().decode(AsyncTaskResponse.self, from: data).accepted) == true
  }
  private func waitForAssistant(
    chatID: String, assistantID: String,
    onToken: @escaping @Sendable (String) -> Void
  ) async throws -> String {
    let deadline = Date().addingTimeInterval(180)
    var delivered = ""
    while Date() < deadline {
      try Task.checkCancellation()
      let (data, _) = try await request(path: "api/v1/chats/\(chatID)")
      if let assistant = assistantText(from: data, assistantID: assistantID) {
        delivered = emitNewContent(assistant.text, after: delivered, onToken: onToken)
        if assistant.done,
          !assistant.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          return assistant.text
        }
      }
      try await Task.sleep(for: .milliseconds(350))
    }
    throw MiddleAIError.network("Timed out waiting for the Open WebUI response")
  }
  private func assistantText(from data: Data, assistantID: String) -> PersistedAssistant? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    let chat = (root["chat"] as? [String: Any]) ?? root
    let history = chat["history"] as? [String: Any]
    let historyMessages = history?["messages"] as? [String: [String: Any]]
    if let message = historyMessages?[assistantID],
      let content = assistantMessageText(message)
    {
      return PersistedAssistant(text: content, done: message["done"] as? Bool == true)
    }
    if let currentID = history?["currentId"] as? String,
      let message = historyMessages?[currentID], message["role"] as? String == "assistant",
      let content = assistantMessageText(message)
    {
      return PersistedAssistant(text: content, done: message["done"] as? Bool == true)
    }
    if let messages = chat["messages"] as? [[String: Any]] {
      if let message = messages.first(where: { $0["id"] as? String == assistantID }),
        let content = assistantMessageText(message)
      {
        return PersistedAssistant(text: content, done: message["done"] as? Bool == true)
      }
      if let message = messages.reversed().first(where: {
        $0["role"] as? String == "assistant"
      }), let content = assistantMessageText(message) {
        return PersistedAssistant(text: content, done: message["done"] as? Bool == true)
      }
    }
    return nil
  }

  private func options(for model: String) async throws -> ModelOptions {
    if let cached = lock.clientLock({ modelOptions[model] }) { return cached }
    _ = try await models()
    return lock.clientLock({ modelOptions[model] }) ?? ModelOptions()
  }

  private static func options(from row: [String: Any]) -> ModelOptions {
    let info = row["info"] as? [String: Any]
    let meta = (info?["meta"] as? [String: Any]) ?? (row["meta"] as? [String: Any]) ?? [:]
    let capabilities = meta["capabilities"] as? [String: Any] ?? [:]
    let featureNames = ["web_search", "code_interpreter", "image_generation"]
    let features = featureNames.reduce(into: [String: Bool]()) { result, name in
      result[name] = capabilities[name] as? Bool == true
    }
    let toolIDs =
      (meta["toolIds"] as? [String]) ?? (meta["tool_ids"] as? [String])
      ?? (row["tool_ids"] as? [String]) ?? []
    return ModelOptions(features: features, toolIDs: toolIDs)
  }
  private func assistantMessageText(_ message: [String: Any]) -> String? {
    if let content = textContent(message["content"]),
      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return content
    }
    guard let output = message["output"] as? [[String: Any]] else { return nil }
    for item in output where item["type"] as? String == "message" {
      if let content = textContent(item["content"]),
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return content
      }
    }
    return nil
  }
  private func textContent(_ value: Any?) -> String? {
    if let text = value as? String { return text }
    if let parts = value as? [[String: Any]] {
      let text = parts.compactMap { part in
        (part["text"] as? String) ?? (part["content"] as? String)
      }.joined()
      return text.isEmpty ? nil : text
    }
    return nil
  }
  private func validated(_ result: CompletionResult) throws -> CompletionResult {
    if result.finishReason == "length" {
      throw MiddleAIError.invalidResponse(
        "OpenWebUI hat die Antwort wegen des Token-Limits abgeschnitten. "
          + "Bitte das Ausgabelimit des Modells erhöhen.")
    }
    if result.requestedToolCall
      && result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw MiddleAIError.invalidResponse(
        "OpenWebUI hat einen Werkzeugaufruf begonnen, aber nicht abgeschlossen.")
    }
    guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MiddleAIError.invalidResponse("Chat completion contains no assistant text")
    }
    return result
  }

  private static func supportsNonStreamingFallback(_ status: Int) -> Bool {
    [400, 404, 405, 406, 415, 422, 501].contains(status)
  }

  @discardableResult
  private func emitNewContent(
    _ candidate: String, after delivered: String,
    onToken: @escaping @Sendable (String) -> Void
  ) -> String {
    guard candidate != delivered else { return delivered }
    if candidate.hasPrefix(delivered) {
      let suffix = String(candidate.dropFirst(delivered.count))
      if !suffix.isEmpty { onToken(suffix) }
      return candidate
    }
    if delivered.hasPrefix(candidate) { return delivered }
    // Persisted messages can be rewritten while a tool is running. Preserve already delivered
    // text and emit only a newly appended suffix; speaking the whole snapshot would duplicate it.
    let common = candidate.commonPrefix(with: delivered)
    let suffix = String(candidate.dropFirst(common.count))
    if !suffix.isEmpty { onToken(suffix) }
    return candidate
  }

  private func stream(
    path: String, json: [String: Any], onToken: @escaping @Sendable (String) -> Void
  ) async throws -> StreamOutcome {
    let request = try authorized(path, method: "POST", json: json)
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw MiddleAIError.invalidResponse("Not HTTP")
    }
    var raw = Data()
    var full = ""
    var finishReason: String?
    var requestedToolCall = false
    var sawSSE = false
    for try await line in bytes.lines {
      try Task.checkCancellation()
      guard line.hasPrefix("data:") else {
        if !sawSSE, raw.count < 1_048_576 {
          raw.append(contentsOf: line.utf8.prefix(1_048_576 - raw.count))
          raw.append(0x0A)
        }
        continue
      }
      sawSSE = true
      let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
      guard payload != "[DONE]", let data = payload.data(using: .utf8) else { continue }
      if let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) {
        if let choice = chunk.choices?.first {
          if let token = choice.delta?.content, !token.isEmpty {
            full += token
            onToken(token)
          } else if let snapshot = choice.message?.content, !snapshot.isEmpty {
            full = emitNewContent(snapshot, after: full, onToken: onToken)
          }
          requestedToolCall =
            requestedToolCall || !(choice.delta?.toolCalls ?? []).isEmpty
            || !(choice.message?.toolCalls ?? []).isEmpty
          finishReason = choice.finishReason ?? finishReason
        } else if let token = chunk.data?.content ?? chunk.content, !token.isEmpty {
          // OpenWebUI-specific chat:completion events carry incremental content here.
          full += token
          onToken(token)
        }
      }
    }
    guard (200..<300).contains(http.statusCode) else {
      let detail = responseDetail(from: raw)
      throw StreamingFailure.rejected(status: http.statusCode, detail: detail)
    }
    if !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return .completed(
        CompletionResult(
          text: full, finishReason: finishReason, requestedToolCall: requestedToolCall))
    }
    if isAsyncTaskResponse(raw) || raw.isEmpty || sawSSE {
      return .asynchronous
    }
    if let result = try? completionResult(from: raw) {
      onToken(result.text)
      return .completed(result)
    }
    // WebUI-shaped streaming requests may deliberately return an empty acknowledgement and
    // publish chunks through its socket channel. Polling the persisted assistant is the portable
    // HTTP fallback and still delivers incremental changes to MiddleAI.
    return .asynchronous
  }
  private func messageJSON(_ m: Message) -> [String: Any] {
    [
      "id": m.id, "role": m.role.rawValue, "content": m.content,
      "timestamp": Int(m.timestamp.timeIntervalSince1970),
    ]
  }
  private func chatSnapshot(title: String, messages: [Message], model: String) -> [String: Any] {
    var history: [String: [String: Any]] = [:]
    for (i, m) in messages.enumerated() {
      var j = messageJSON(m)
      j["parentId"] = i == 0 ? nil : messages[i - 1].id
      j["childrenIds"] = i + 1 < messages.count ? [messages[i + 1].id] : []
      history[m.id] = j
    }
    return [
      "id": "", "title": title, "models": [model], "messages": messages.map(messageJSON),
      "history": ["messages": history, "currentId": messages.last?.id ?? ""], "params": [:],
    ]
  }
}

private final class TLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
  let verify: Bool
  let anchor: SecCertificate?
  init(verify: Bool, caFile: String?) {
    self.verify = verify
    if let caFile, let data = try? Data(contentsOf: URL(fileURLWithPath: caFile)) {
      self.anchor = SecCertificateCreateWithData(nil, data as CFData)
    } else {
      self.anchor = nil
    }
  }
  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust = challenge.protectionSpace.serverTrust
    else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    if !verify {
      completionHandler(.useCredential, URLCredential(trust: trust))
      return
    }
    if let anchor {
      SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
      SecTrustSetAnchorCertificatesOnly(trust, false)
    }
    var error: CFError?
    if SecTrustEvaluateWithError(trust, &error) {
      completionHandler(.useCredential, URLCredential(trust: trust))
    } else {
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }
}

extension NSLock {
  fileprivate func clientLock<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}
