import Foundation
import Security

public protocol AssistantClientProtocol: Sendable {
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

extension AssistantClientProtocol {
  public func cancel(chatID: String) async {}
}

@available(*, deprecated, renamed: "AssistantClientProtocol")
public typealias OpenWebUIClientProtocol = AssistantClientProtocol

public final class OpenWebUIClient: AssistantClientProtocol, @unchecked Sendable {
  private struct ModelOptions: Sendable {
    var features: [String: Bool] = [:]
    var toolIDs: [String] = []
  }

  private struct CompletionResult: Sendable {
    let text: String
    let finishReason: String?
    let requestedToolCall: Bool
  }

  private struct PersistedAssistant: Sendable {
    let text: String
    let done: Bool?
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
    case asynchronous(taskIDs: [String])
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
      switch try await stream(
        path: "api/chat/completions", json: body,
        deliverProvisionalTokens: true, onToken: onToken)
      {
      case .completed(let streamed):
        initial = try validated(streamed)
      case .asynchronous(let taskIDs):
        let persisted = try await waitForAssistant(
          chatID: chatID, assistantID: assistantID, expectedTaskIDs: taskIDs,
          onToken: onToken)
        initial = CompletionResult(text: persisted, finishReason: "stop", requestedToolCall: false)
      }
    } catch let StreamingFailure.rejected(status, _) where Self.supportsNonStreamingFallback(status)
    {
      // Some OpenWebUI adapters only expose a non-streaming chat-completions response over
      // HTTP. Retrying is safe here because a rejected request did not start a generation.
      body["stream"] = false
      let data = try await request(path: "api/chat/completions", method: "POST", json: body).0
      if let taskIDs = asyncTaskIDs(from: data) {
        let persisted = try await waitForAssistant(
          chatID: chatID, assistantID: assistantID, expectedTaskIDs: taskIDs,
          onToken: onToken)
        initial = CompletionResult(text: persisted, finishReason: "stop", requestedToolCall: false)
      } else {
        let completion = try completionResult(from: data)
        if completion.requestedToolCall {
          let persisted = try await waitForAssistant(
            chatID: chatID, assistantID: assistantID, expectedTaskIDs: [], onToken: onToken)
          initial = CompletionResult(
            text: persisted, finishReason: "stop", requestedToolCall: false)
        } else {
          initial = try validated(completion)
          onToken(completion.text)
        }
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
    var finalized = initial.text
    if let finalizedData = try? await request(
      path: "api/chat/completed", method: "POST", json: completionBody
    ).0 {
      finalized = completionTextIfPresent(from: finalizedData) ?? finalized
    }
    try Task.checkCancellation()
    _ = try? await request(
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
  private func asyncTaskIDs(from data: Data) -> [String]? {
    guard let response = try? JSONDecoder().decode(AsyncTaskResponse.self, from: data),
      response.accepted
    else { return nil }
    return response.taskIDs ?? []
  }
  private func waitForAssistant(
    chatID: String, assistantID: String,
    expectedTaskIDs: [String],
    onToken: @escaping @Sendable (String) -> Void
  ) async throws -> String {
    let deadline = Date().addingTimeInterval(180)
    var delivered = ""
    var lastSnapshot = ""
    var stablePolls = 0
    var observedActiveTask = !expectedTaskIDs.isEmpty
    while Date() < deadline {
      try Task.checkCancellation()
      let (data, _) = try await request(path: "api/v1/chats/\(chatID)")
      if let assistant = assistantText(from: data, assistantID: assistantID) {
        if assistant.text == lastSnapshot {
          stablePolls += 1
        } else {
          lastSnapshot = assistant.text
          stablePolls = 0
        }
        delivered = emitNewContent(assistant.text, after: delivered, onToken: onToken)
        if assistant.done == true,
          !assistant.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          return assistant.text
        }
        if assistant.done == nil,
          !assistant.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          if let activeTasks = await activeTaskIDs(chatID: chatID) {
            if !activeTasks.isEmpty { observedActiveTask = true }
            if activeTasks.isEmpty, observedActiveTask, stablePolls >= 1,
              !Self.isLikelyToolPreamble(assistant.text)
            {
              return assistant.text
            }
          } else if stablePolls >= 12, !Self.isLikelyToolPreamble(assistant.text) {
            return assistant.text
          }
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
      return PersistedAssistant(text: content, done: completionFlag(message))
    }
    if let currentID = history?["currentId"] as? String,
      let message = historyMessages?[currentID], message["role"] as? String == "assistant",
      let content = assistantMessageText(message)
    {
      return PersistedAssistant(text: content, done: completionFlag(message))
    }
    if let messages = chat["messages"] as? [[String: Any]] {
      if let message = messages.first(where: { $0["id"] as? String == assistantID }),
        let content = assistantMessageText(message)
      {
        return PersistedAssistant(text: content, done: completionFlag(message))
      }
      if let message = messages.reversed().first(where: {
        $0["role"] as? String == "assistant"
      }), let content = assistantMessageText(message) {
        return PersistedAssistant(text: content, done: completionFlag(message))
      }
    }
    return nil
  }

  private func completionFlag(_ message: [String: Any]) -> Bool? {
    if let done = message["done"] as? Bool { return done }
    if let status = message["status"] as? String {
      if ["complete", "completed", "done", "success"].contains(status.lowercased()) {
        return true
      }
      if ["pending", "running", "in_progress"].contains(status.lowercased()) { return false }
    }
    return nil
  }

  private func activeTaskIDs(chatID: String) async -> [String]? {
    guard let data = try? await request(path: "api/tasks/chat/\(chatID)").0,
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return root["task_ids"] as? [String]
  }

  private static func isLikelyToolPreamble(_ text: String) -> Bool {
    let normalized = text.folding(
      options: [.diacriticInsensitive, .caseInsensitive], locale: .current
    ).lowercased()
    return [
      "ich starte", "ich recherchiere", "ich suche", "ich prüfe", "ich schaue nach",
      "i will search", "i'll search", "let me search", "i will research", "let me check",
    ].contains(where: normalized.contains)
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
    // Tool runs can replace a preamble with the actual answer. Do not append the rewritten body
    // to already delivered text; MiddleAIEngine reconciles the canonical final response once.
    return delivered
  }

  private func stream(
    path: String, json: [String: Any], deliverProvisionalTokens: Bool,
    onToken: @escaping @Sendable (String) -> Void
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
    var taskIDs: [String] = []
    var explicitDone = false
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
      if payload == "[DONE]" {
        explicitDone = true
        continue
      }
      guard let data = payload.data(using: .utf8) else { continue }
      if let asynchronous = try? JSONDecoder().decode(AsyncTaskResponse.self, from: data),
        asynchronous.accepted
      {
        taskIDs = asynchronous.taskIDs ?? []
        continue
      }
      if let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) {
        if let choice = chunk.choices?.first {
          if let token = choice.delta?.content, !token.isEmpty {
            full += token
            if deliverProvisionalTokens { onToken(token) }
          } else if let snapshot = choice.message?.content, !snapshot.isEmpty {
            if deliverProvisionalTokens {
              full = emitNewContent(snapshot, after: full, onToken: onToken)
            } else {
              full = snapshot
            }
          }
          requestedToolCall =
            requestedToolCall || !(choice.delta?.toolCalls ?? []).isEmpty
            || !(choice.message?.toolCalls ?? []).isEmpty
          finishReason = choice.finishReason ?? finishReason
        } else if let token = chunk.data?.content ?? chunk.content, !token.isEmpty {
          // OpenWebUI-specific chat:completion events carry incremental content here.
          full += token
          if deliverProvisionalTokens { onToken(token) }
        }
        explicitDone = explicitDone || chunk.data?.done == true || chunk.done == true
      }
    }
    guard (200..<300).contains(http.statusCode) else {
      let detail = responseDetail(from: raw)
      throw StreamingFailure.rejected(status: http.statusCode, detail: detail)
    }
    if finishReason == "length" {
      return .completed(
        CompletionResult(
          text: full, finishReason: finishReason, requestedToolCall: requestedToolCall))
    }
    if finishReason == "content_filter" {
      throw MiddleAIError.invalidResponse(
        "OpenWebUI hat die Antwort wegen eines Inhaltsfilters beendet.")
    }
    if finishReason == "error" {
      throw MiddleAIError.network("OpenWebUI hat die laufende Antwort mit einem Fehler beendet.")
    }
    if let finishReason,
      !["stop", "tool_calls", "function_call"].contains(finishReason)
    {
      throw MiddleAIError.invalidResponse(
        "OpenWebUI meldet den unbekannten Abschlussgrund \(finishReason).")
    }
    let terminal = finishReason == "stop" || (finishReason == nil && explicitDone)
    if terminal, taskIDs.isEmpty, !requestedToolCall,
      !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      if !deliverProvisionalTokens { onToken(full) }
      return .completed(
        CompletionResult(
          text: full, finishReason: finishReason, requestedToolCall: requestedToolCall))
    }
    if let asynchronousIDs = asyncTaskIDs(from: raw) {
      taskIDs = asynchronousIDs
    }
    if !taskIDs.isEmpty || raw.isEmpty || sawSSE || requestedToolCall {
      return .asynchronous(taskIDs: taskIDs)
    }
    if let result = try? completionResult(from: raw) {
      if result.requestedToolCall { return .asynchronous(taskIDs: taskIDs) }
      let completed = try validated(result)
      onToken(completed.text)
      return .completed(completed)
    }
    // WebUI-shaped streaming requests may deliberately return an empty acknowledgement and
    // publish chunks through its socket channel. Polling the persisted assistant is the portable
    // HTTP fallback and still delivers incremental changes to MiddleAI.
    return .asynchronous(taskIDs: taskIDs)
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
