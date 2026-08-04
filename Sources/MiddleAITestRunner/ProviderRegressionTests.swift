import Foundation
import MiddleAICore

enum ProviderRegressionTests {
  static func testOpenWebUICompletionState() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProviderMockProtocol.self]
    let client = OpenWebUIClient(
      baseURL: URL(string: "https://example.test")!, auth: StaticAuth(),
      session: URLSession(configuration: configuration))
    let polls = ProviderCounter()
    let finalized = ProviderCounter()
    ProviderMockProtocol.handler = { request in
      switch (request.url?.path, request.httpMethod) {
      case ("/api/models", _):
        return ProviderResponse(
          status: 200,
          body: Data(
            #"{"data":[{"id":"model","info":{"meta":{"capabilities":{"web_search":true},"toolIds":["search"]}}}]}"#
              .utf8))
      case ("/api/chat/completions", _):
        let stream = """
          data: {"choices":[{"delta":{"content":"Ich starte die Recherche."}}]}

          data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

          data: {"status":true,"task_ids":["research-1"]}

          data: [DONE]

          """
        return ProviderResponse(status: 200, body: Data(stream.utf8))
      case ("/api/v1/chats/test-chat", "GET"):
        let poll = polls.increment()
        let content = poll == 1 ? "Ich starte die Recherche." : "Das ist die finale Antwort."
        return ProviderResponse(
          status: 200,
          body: Data(
            "{\"chat\":{\"history\":{\"currentId\":\"assistant\",\"messages\":{\"assistant\":{\"role\":\"assistant\",\"content\":\"\(content)\"}}}}}"
              .utf8))
      case ("/api/tasks/chat/test-chat", _):
        let active = polls.value <= 1 ? ["research-1"] : []
        return ProviderResponse(
          status: 200,
          body: try JSONSerialization.data(withJSONObject: ["task_ids": active]))
      case ("/api/chat/completed", _):
        _ = finalized.increment()
        return ProviderResponse(status: 500, body: Data("temporary outlet failure".utf8))
      case ("/api/v1/chats/test-chat", _):
        return ProviderResponse(status: 200, body: Data("{}".utf8))
      default:
        return ProviderResponse(status: 404, body: Data())
      }
    }
    try await client.authenticate()
    _ = try await client.models()
    let tokens = LockedTokens()
    let answer = try await client.send(
      messages: [Message(role: .user, content: "Recherchiere")], chatID: "test-chat",
      model: "model"
    ) { tokens.append($0) }
    try expect(answer == "Das ist die finale Antwort.", "research preamble is not final")
    try expect(finalized.value == 1, "completion lifecycle attempted exactly once")
  }

  static func testHostedRetryAndFinishes() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProviderMockProtocol.self]
    let credentials = MemoryCredentialStore()
    try credentials.save("sk-test", account: HostedAIProvider.openai.credentialAccount)
    let attempts = ProviderCounter()
    let delays = ProviderDurations()
    ProviderMockProtocol.handler = { _ in
      if attempts.increment() == 1 {
        return ProviderResponse(
          status: 429, body: Data(#"{"error":{"message":"rate limited"}}"#.utf8),
          headers: ["Retry-After": "60"])
      }
      let stream = """
        data: {"choices":[{"delta":{"content":"Erfolg"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """
      return ProviderResponse(status: 200, body: Data(stream.utf8))
    }
    let client = HostedAIClient(
      provider: .openai, credentials: credentials,
      session: URLSession(configuration: configuration),
      retrySleeper: { delays.append($0) })
    let answer = try await client.send(
      messages: [Message(role: .user, content: "Test")], chatID: "local", model: "model"
    ) { _ in }
    try expect(answer == "Erfolg", "hosted retry succeeds")
    try expect(attempts.value == 2, "429 retried once")
    try expect(delays.values == [.seconds(8)], "Retry-After is bounded")

    for reason in ["length", "tool_calls"] {
      ProviderMockProtocol.handler = { _ in
        let tool = reason == "tool_calls" ? #", "tool_calls":[{}]"# : ""
        let stream =
          "data: {\"choices\":[{\"delta\":{\"content\":\"Teil\"\(tool)},\"finish_reason\":\"\(reason)\"}]}\n\ndata: [DONE]\n\n"
        return ProviderResponse(status: 200, body: Data(stream.utf8))
      }
      do {
        _ = try await client.send(
          messages: [Message(role: .user, content: "Test")], chatID: "local", model: "model"
        ) { _ in }
        throw TestFailure.failed("hosted finish reason \(reason) accepted")
      } catch is TestFailure {
        throw TestFailure.failed("hosted finish reason \(reason) accepted")
      } catch let error as MiddleAIError {
        guard case .invalidResponse = error else {
          throw TestFailure.failed("hosted finish reason \(reason) mapped incorrectly")
        }
      }
    }
  }

  @MainActor static func testRequestSerialization() async throws {
    let client = SerialProviderClient()
    let manager = ConversationManager(
      store: InMemoryConversationStore(),
      router: FixedRouter(
        result: RoutingDecision(decision: .newChat, confidence: 0.9, reason: "test")))
    var config = AppConfig()
    config.openwebui.model = "model"
    let engine = MiddleAIEngine(
      manager: manager, client: client, ttsQueue: TTSQueue(provider: RecordingTTS()),
      config: config)
    async let first = engine.handle(text: "Erste Anfrage", source: "http")
    async let second = engine.handle(text: "Zweite Anfrage", source: "http")
    _ = try await (first, second)
    try expect(client.maximumActive == 1, "provider requests serialized")
    try expect(client.cancelCount == 0, "parallel request did not barge in")

    let interruptibleClient = SerialProviderClient(delay: .seconds(2))
    let interruptibleEngine = MiddleAIEngine(
      manager: ConversationManager(
        store: InMemoryConversationStore(),
        router: FixedRouter(
          result: RoutingDecision(decision: .newChat, confidence: 0.9, reason: "test"))),
      client: interruptibleClient, ttsQueue: TTSQueue(provider: RecordingTTS()), config: config)
    let interrupted = Task {
      try await interruptibleEngine.handle(text: "Lange Anfrage", source: "voice")
    }
    try await Task.sleep(for: .milliseconds(25))
    interruptibleEngine.interrupt()
    do {
      _ = try await interrupted.value
      throw TestFailure.failed("explicit barge-in did not cancel active provider request")
    } catch is CancellationError {
      // Expected: explicit user interruption bypasses the serialization queue.
    }
    try await Task.sleep(for: .milliseconds(10))
    try expect(interruptibleClient.cancelCount == 1, "barge-in reached provider cancellation")
  }

  static func testAtomicExchange() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "middleai-exchange-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SQLiteConversationStore(
      path: directory.appendingPathComponent("cache.sqlite").path)
    var conversation = Conversation(title: "Atomic")
    try store.saveConversation(conversation)
    conversation.summary = "Complete"
    let user = Message(role: .user, content: "Frage")
    let assistant = Message(role: .assistant, content: "Antwort")
    try store.saveExchange(user: user, assistant: assistant, conversation: conversation)
    let storedMessages = try store.messages(conversationID: conversation.id, limit: 10)
    let storedConversation = try store.conversation(id: conversation.id)
    try expect(
      storedMessages.count == 2
        && storedMessages[0].id == user.id
        && storedMessages[0].role == .user
        && storedMessages[0].content == user.content
        && storedMessages[1].id == assistant.id
        && storedMessages[1].role == .assistant
        && storedMessages[1].content == assistant.content,
      "atomic exchange stores both messages")
    try expect(
      storedConversation?.summary == "Complete",
      "atomic exchange stores conversation metadata")
  }

  static func testContextBudget() throws {
    let messages =
      [Message(role: .system, content: "Systemregeln")]
      + (0..<30).map { index in
        Message(
          role: index.isMultiple(of: 2) ? .user : .assistant,
          content: "Nachricht \(index) " + String(repeating: "Inhalt ", count: 80))
      }
    let prepared = HostedContextWindow.prepared(messages, maximumEstimatedTokens: 700)
    try expect(HostedContextWindow.estimatedTokens(prepared) <= 700, "context budget enforced")
    try expect(prepared.first?.role == .system, "system prompt retained")
    try expect(prepared.last?.content.contains("Nachricht 29") == true, "newest turn retained")
    try expect(
      prepared.contains(where: { $0.content.contains("Lokale Zusammenfassung") }),
      "older turns summarized locally")
  }

  static func testLocalSpokenSummary() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProviderMockProtocol.self]
    let calls = ProviderCounter()
    ProviderMockProtocol.handler = { request in
      _ = calls.increment()
      guard request.url?.path == "/v1/chat/completions" else {
        return ProviderResponse(status: 404, body: Data())
      }
      return ProviderResponse(
        status: 200,
        body: Data(
          #"{"choices":[{"message":{"content":"Das wichtigste Ergebnis sind 18 Prozent Wachstum. Als nächster Schritt empfiehlt sich ein klar gemessenes Pilotprojekt."}}]}"#
            .utf8))
    }
    var local = AppConfig().localLLM
    local.enabled = true
    local.provider = "llama_cpp"
    local.url = "http://127.0.0.1:18881"
    local.model = "test-model"
    local.timeoutSeconds = 2
    let summarizer = SpokenResponseSummarizer(
      localLLM: local, session: URLSession(configuration: configuration),
      systemModelEnabled: false)
    let source = Array(
      repeating:
        "Das wichtigste Ergebnis sind 18 Prozent Wachstum. Als nächster Schritt empfiehlt sich ein klar gemessenes Pilotprojekt.",
      count: 12
    ).joined(separator: " ")
    let result = await summarizer.spokenText(for: source, threshold: 100, maximumWords: 40)
    try expect(calls.value == 1, "local summary endpoint used")
    try expect(result.contains("18 Prozent"), "local summary preserves grounded figures")
    try expect(result.hasSuffix("."), "local summary ends at a sentence boundary")

    try expect(
      !SpokenResponseSummarizer.isGroundedSummary(
        "Das Ergebnis sind 99 Prozent Wachstum.", in: source, maximumWords: 40),
      "invented figures are rejected")
  }
}

private struct ProviderResponse {
  let status: Int
  let body: Data
  var headers: [String: String] = [:]
}

private final class ProviderMockProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> ProviderResponse)?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let result = try Self.handler?(request) ?? ProviderResponse(status: 500, body: Data())
      let response = HTTPURLResponse(
        url: request.url!, statusCode: result.status, httpVersion: nil,
        headerFields: result.headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: result.body)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }
  override func stopLoading() {}
}

private final class ProviderCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0
  var value: Int { lock.withLock { storage } }
  func increment() -> Int {
    lock.withLock {
      storage += 1
      return storage
    }
  }
}

private final class ProviderDurations: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Duration] = []
  var values: [Duration] { lock.withLock { storage } }
  func append(_ value: Duration) { lock.withLock { storage.append(value) } }
}

private final class SerialProviderClient: AssistantClientProtocol, @unchecked Sendable {
  private let lock = NSLock()
  private var active = 0
  private var maximum = 0
  private var cancellations = 0
  private let delay: Duration
  init(delay: Duration = .milliseconds(35)) { self.delay = delay }
  var maximumActive: Int { lock.withLock { maximum } }
  var cancelCount: Int { lock.withLock { cancellations } }
  func authenticate() async throws {}
  func health() async throws {}
  func models() async throws -> [String] { ["model"] }
  func createChat(title: String, messages: [Message], model: String) async throws -> String {
    UUID().uuidString
  }
  func send(
    messages: [Message], chatID: String, model: String,
    onToken: @escaping @Sendable (String) -> Void
  ) async throws -> String {
    lock.withLock {
      active += 1
      maximum = max(maximum, active)
    }
    defer { lock.withLock { active -= 1 } }
    try await Task.sleep(for: delay)
    onToken("Antwort")
    return "Antwort"
  }
  func cancel(chatID: String) async { lock.withLock { cancellations += 1 } }
  func listChats() async throws -> [(id: String, title: String)] { [] }
  func chatURL(id: String) -> URL { URL(string: "https://example.test/\(id)")! }
}
