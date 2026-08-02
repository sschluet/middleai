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
  func listChats() async throws -> [(id: String, title: String)]
  func chatURL(id: String) -> URL
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

  public let baseURL: URL
  private let auth: any AuthProvider
  private let session: URLSession
  private let tlsVerify: Bool
  private let caFile: String?
  private let lock = NSLock()
  private var bearer: String?
  private var modelOptions: [String: ModelOptions] = [:]
  public init(
    baseURL: URL, auth: any AuthProvider, tlsVerify: Bool = true, caFile: String? = nil,
    session: URLSession? = nil
  ) {
    self.baseURL = baseURL
    self.auth = auth
    self.tlsVerify = tlsVerify
    self.caFile = caFile
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
    let body: [String: Any] = [
      "model": model, "messages": messages.map(messageJSON), "stream": false, "chat_id": chatID,
      "id": assistantID, "session_id": sessionID, "tool_ids": options.toolIDs, "files": [],
      "features": features, "metadata": metadata,
      "background_tasks": [
        "title_generation": false, "tags_generation": false, "follow_up_generation": false,
      ],
    ]
    let (data, _) = try await request(path: "api/chat/completions", method: "POST", json: body)
    let initial: CompletionResult
    if let immediate = try? completionResult(from: data), immediate.isComplete {
      initial = immediate
    } else if isAsyncTaskResponse(data) {
      let persisted = try await waitForAssistant(chatID: chatID, assistantID: assistantID)
      initial = CompletionResult(text: persisted, finishReason: "stop", requestedToolCall: false)
    } else if let incomplete = try? completionResult(from: data), incomplete.finishReason == "length" {
      throw MiddleAIError.invalidResponse(
        "OpenWebUI hat die Antwort wegen des Token-Limits abgeschnitten. Bitte das Ausgabelimit des Modells erhöhen.")
    } else if let toolCall = try? completionResult(from: data), toolCall.requestedToolCall {
      throw MiddleAIError.invalidResponse(
        "OpenWebUI hat einen Werkzeugaufruf begonnen, aber nicht abgeschlossen.")
    } else {
      initial = try completionResult(from: data)
    }
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
      path: "api/chat/completed", method: "POST", json: completionBody).0
    let finalized = completionTextIfPresent(from: finalizedData) ?? initial.text
    _ = try await request(
      path: "api/v1/chats/\(chatID)", method: "POST",
      json: [
        "chat": chatSnapshot(
          title: title,
          messages: messages + [Message(id: assistantID, role: .assistant, content: finalized)],
          model: model)
      ])
    onToken(finalized)
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
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return false
    }
    return root["status"] as? Bool == true && root["task_ids"] is [Any]
  }
  private func waitForAssistant(chatID: String, assistantID: String) async throws -> String {
    let deadline = Date().addingTimeInterval(180)
    while Date() < deadline {
      let (data, _) = try await request(path: "api/v1/chats/\(chatID)")
      if let assistant = assistantText(from: data, assistantID: assistantID), assistant.done,
        !assistant.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return assistant.text
      }
      try await Task.sleep(nanoseconds: 500_000_000)
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
  private func stream(
    path: String, json: [String: Any], onToken: @escaping @Sendable (String) -> Void
  ) async throws -> String {
    let request = try authorized(path, method: "POST", json: json)
    let delegate = SSEDelegate(onToken: onToken, verify: tlsVerify, caFile: caFile)
    let streaming = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    defer { streaming.finishTasksAndInvalidate() }
    return try await withCheckedThrowingContinuation { continuation in
      delegate.completion = continuation
      streaming.dataTask(with: request).resume()
    }
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

private final class SSEDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  let onToken: @Sendable (String) -> Void
  var completion: CheckedContinuation<String, Error>?
  private var buffer = ""
  private var full = ""
  private var status = 200
  private let verify: Bool
  private let anchor: SecCertificate?
  init(onToken: @escaping @Sendable (String) -> Void, verify: Bool, caFile: String?) {
    self.onToken = onToken
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
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    status = (response as? HTTPURLResponse)?.statusCode ?? 0
    completionHandler(.allow)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    buffer += String(decoding: data, as: UTF8.self)
    while let range = buffer.range(of: "\n") {
      let line = String(buffer[..<range.lowerBound])
      buffer.removeSubrange(...range.lowerBound)
      parse(line)
    }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error {
      completion?.resume(throwing: error)
    } else if !(200..<300).contains(status) {
      completion?.resume(throwing: MiddleAIError.network("Open WebUI returned HTTP \(status)"))
    } else {
      completion?.resume(returning: full)
    }
    completion = nil
  }
  private func parse(_ line: String) {
    guard line.hasPrefix("data:") else { return }
    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
    guard payload != "[DONE]", let data = payload.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return }
    let choice = (root["choices"] as? [[String: Any]])?.first
    let token =
      ((choice?["delta"] as? [String: Any])?["content"] as? String)
      ?? ((choice?["message"] as? [String: Any])?["content"] as? String) ?? ""
    if !token.isEmpty {
      full += token
      onToken(token)
    }
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
