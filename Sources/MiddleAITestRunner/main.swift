import Foundation
import MiddleAICore

enum TestFailure: Error, CustomStringConvertible {
  case failed(String)
  var description: String {
    switch self {
    case .failed(let s): return s
    }
  }
}
func expect(_ condition: @autoclosure () -> Bool, _ name: String) throws {
  guard condition() else { throw TestFailure.failed(name) }
}
func requestJSON(_ request: URLRequest) throws -> [String: Any] {
  var data = request.httpBody ?? Data()
  if data.isEmpty, let stream = request.httpBodyStream {
    stream.open()
    defer { stream.close() }
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
  }
  return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}
struct FixedRouter: ConversationRoutingStrategy {
  let result: RoutingDecision
  func route(_ context: ConversationContext) async throws -> RoutingDecision { result }
}

@main struct MiddleAITestRunner {
  @MainActor static func main() async {
    var passed = 0
    var failed = 0
    let tests: [(String, () async throws -> Void)] = [
      ("Config", testConfig), ("Storage", testStorage), ("Commands", testCommands),
      ("SentenceBuffer", testSentenceBuffer), ("Speech text", testSpeechText),
      ("HeuristicRouter continuation", testRouterContinuation),
      ("HeuristicRouter new topic", testRouterNewTopic), ("HybridRouter", testHybrid),
      ("ConversationManager", testManager), ("Confidence management", testConfidence),
      ("TTS queue/barge-in", testTTSQueue), ("Response delivery", testResponseDelivery),
      ("OpenWebUI adapter", testAdapter),
    ]
    for (name, test) in tests {
      do {
        try await test()
        print("✓ \(name)")
        passed += 1
      } catch {
        print("✗ \(name): \(error)")
        failed += 1
      }
    }
    print("\n\(passed) passed, \(failed) failed")
    if failed > 0 { exit(1) }
  }
  static func testConfig() async throws {
    var c = AppConfig()
    c.openwebui.url = "https://ai.internal"
    c.dictation.polishWithLocalAI = false
    c.hotkeys.dictation = "left_control"
    c.hotkeys.assistant = "right_command"
    let parsed = try ConfigLoader.parseYAML(ConfigLoader.renderYAML(c))
    try expect(parsed.openwebui.url == "https://ai.internal", "URL round-trip")
    try expect(parsed.openwebui.tlsVerify, "TLS default")
    try expect(parsed.tts.localOnly, "local TTS")
    try expect(parsed.tts.provider == "adaptive", "adaptive German TTS default")
    try expect(parsed.spokenResponseMode == "smart_summary", "smart spoken summary default")
    try expect(parsed.spokenResponseThreshold == 850, "spoken summary threshold round-trip")
    try expect(!parsed.dictation.polishWithLocalAI, "dictation polishing round-trip")
    try expect(
      parsed.hotkeys.dictation == "left_control" && parsed.hotkeys.assistant == "right_command",
      "activation keys round-trip")
    try expect(
      TTSVoiceCatalog.supertonicVoices.count == 5
        && TTSVoiceCatalog.supertonicVoices.allSatisfy(\.isFemale),
      "female Supertonic voice catalog")
    try expect(
      TTSVoiceCatalog.qwenVoices.count == 3
        && TTSVoiceCatalog.qwenVoices.allSatisfy(\.isFemale),
      "female Qwen3-TTS voice catalog")
    try expect(
      TTSVoiceCatalog.voxtralVoices.count == 3
        && TTSVoiceCatalog.voxtralVoices.allSatisfy(\.isFemale)
        && TTSVoiceCatalog.defaultVoice(for: "voxtral_tts") == "de_female",
      "female Voxtral voice catalog")
    let unsafe = ConfigLoader.renderYAML(c).replacingOccurrences(
      of: "bind: \"127.0.0.1\"", with: "bind: \"0.0.0.0\"")
    do {
      _ = try ConfigLoader.parseYAML(unsafe)
      throw TestFailure.failed("unsafe listener accepted")
    } catch is MiddleAIError {}
    let conflictingKeys = ConfigLoader.renderYAML(c).replacingOccurrences(
      of: "assistant: \"right_command\"", with: "assistant: \"left_control\"")
    do {
      _ = try ConfigLoader.parseYAML(conflictingKeys)
      throw TestFailure.failed("conflicting activation keys accepted")
    } catch is MiddleAIError {}
  }
  static func testStorage() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".sqlite"
    ).path
    let store = try SQLiteConversationStore(path: path)
    let c = Conversation(title: "Pumps")
    var scoped = c
    scoped.openWebUIChatID = "remote-chat"
    scoped.openWebUIBaseURL = "https://ai.example"
    try store.saveConversation(scoped)
    try store.saveMessage(Message(role: .user, content: "Gardena"), conversationID: c.id)
    let savedConversation = try store.conversation(id: c.id)
    let savedMessages = try store.messages(conversationID: c.id, limit: 10)
    try expect(savedConversation?.title == "Pumps", "conversation persistence")
    try expect(savedConversation?.openWebUIBaseURL == "https://ai.example", "remote scope persistence")
    try expect(savedMessages.first?.content == "Gardena", "message persistence")
  }
  static func testCommands() async throws {
    let d = CommandDetector()
    try expect(d.detect("Stopp") == LocalCommand.stop, "stop")
    try expect(
      d.detect("Architekturmodus") == LocalCommand.switchProfile("architecture"), "profile")
    try expect(d.detect("Zurück zum MacBook-Thema") == LocalCommand.topic("macbook"), "topic")
    try expect(d.detect("Normale Frage") == nil, "normal input")
  }
  static func testSentenceBuffer() async throws {
    var b = SentenceBuffer()
    try expect(b.append("Ein halber").isEmpty, "fragment emitted")
    try expect(b.append(" Satz. Weiter") == ["Ein halber Satz."], "sentence")
    try expect(b.flush() == "Weiter", "flush")
  }
  static func testSpeechText() async throws {
    let decimal = SpeechTextProcessor.normalizeGermanNumbers(in: "3,5 Millionen Datensätze")
    try expect(decimal == "drei Komma fünf Millionen Datensätze", "German decimal spelling")
    let grouped = SpeechTextProcessor.normalizeGermanNumbers(in: "Das sind 1.250.000 Einträge.")
    try expect(!grouped.contains("1.250.000") && grouped.contains("Million"), "grouped number spelling")
    let segments = SpeechTextProcessor.segments(
      for: "Der Python Workflow verarbeitet 3,5 Millionen Datensätze.")
    try expect(segments.contains(where: { $0.language == .english && $0.text.contains("Python") }), "English pronunciation segment")
    try expect(segments.contains(where: { $0.language == .german && $0.text.contains("drei Komma fünf") }), "German number segment")
    let prepared = SpeechTextProcessor.speechReadyGermanText(
      "**Python Workflow:** 3,5 Millionen Datensätze")
    try expect(!prepared.contains("**") && prepared.contains("Peiton Wörkfloh"), "continuous German pronunciation preparation")
    try expect(
      SpeechTextProcessor.prefersPreciseGermanVoice("Das Ergebnis beträgt 3,5 Millionen."),
      "numbers prefer precise German voice")
    try expect(
      SpokenResponseSummarizer.plainText("## Ergebnis\n- **Wichtig**") == "Ergebnis. Wichtig",
      "spoken Markdown cleanup")
    try expect(
      MiddleAIEngine.remoteScope("HTTPS://AI.EXAMPLE/") == "https://ai.example",
      "remote server scope normalization")
    try expect(
      MiddleAIEngine.removingUnansweredUserSuffix(from: [
        Message(role: .assistant, content: "Antwort"),
        Message(role: .user, content: "Fehlgeschlagen"),
      ]).count == 1,
      "failed user suffix excluded from retry")
  }
  static func testRouterContinuation() async throws {
    let now = Date()
    let c = Conversation(
      title: "Gartenpumpen", summary: "Gardena Hauswasserwerk",
      lastUsedAt: now.addingTimeInterval(-20))
    let r = try await HeuristicRouter().route(
      ConversationContext(
        input: "Und wie sieht es mit Gardena aus?", current: c, recent: [c], messages: [:], now: now
      ))
    try expect(r.decision == RoutingDecisionKind.continueCurrent, "continuation")
  }
  static func testRouterNewTopic() async throws {
    let now = Date()
    let c = Conversation(
      title: "Gartenpumpen", summary: "Wasser Garten", lastUsedAt: now.addingTimeInterval(-10_800))
    let r = try await HeuristicRouter().route(
      ConversationContext(
        input: "Welche RAM Konfiguration beim MacBook Pro?", current: c, recent: [c], messages: [:],
        now: now))
    try expect(r.decision == RoutingDecisionKind.newChat, "new topic")
  }
  static func testHybrid() async throws {
    let c = Conversation(
      title: "MacBook RAM", summary: "Apple Silicon Speicher", lastUsedAt: Date())
    let r = try await HybridRouter(heuristic: HeuristicRouter()).route(
      ConversationContext(input: "Und welcher Speicher?", current: c, recent: [c], messages: [:]))
    try expect(r.decision == RoutingDecisionKind.continueCurrent, "hybrid decision")
    try expect(r.confidence > 0.6, "hybrid confidence")
  }
  static func testManager() async throws {
    let store = InMemoryConversationStore()
    let manager = ConversationManager(
      store: store,
      router: FixedRouter(
        result: RoutingDecision(decision: .newChat, confidence: 0.9, reason: "test")))
    let c = try manager.create(title: "Pumps", profile: "default")
    try expect(manager.currentConversation?.id == c.id, "active conversation")
    let (_, r) = try await manager.select(for: "MacBook")
    try expect(r.decision == RoutingDecisionKind.newChat, "routing")
  }
  static func testConfidence() async throws {
    let store = InMemoryConversationStore()
    let manager = ConversationManager(
      store: store,
      router: FixedRouter(
        result: RoutingDecision(decision: .newChat, confidence: 0.2, reason: "test")),
      confidenceAsk: 0.55)
    _ = try manager.create(title: "Pumps", profile: "default")
    let (_, r) = try await manager.select(for: "Maybe")
    try expect(r.decision == RoutingDecisionKind.askUser, "ask user")
  }
  @MainActor static func testTTSQueue() async throws {
    let provider = RecordingTTS()
    let queue = TTSQueue(provider: provider)
    queue.enqueue("One.")
    queue.enqueue("Two.")
    try await Task.sleep(nanoseconds: 20_000_000)
    queue.stop()
    try expect(provider.spoken.contains("One."), "queued speech")
    try expect(provider.stopped, "barge-in")
  }
  @MainActor static func testResponseDelivery() async throws {
    let provider = RecordingTTS()
    let queue = TTSQueue(provider: provider)
    let manager = ConversationManager(
      store: InMemoryConversationStore(),
      router: FixedRouter(
        result: RoutingDecision(decision: .newChat, confidence: 0.9, reason: "test")))
    var config = AppConfig()
    config.openwebui.model = "test-model"
    let engine = MiddleAIEngine(
      manager: manager, client: FixedResponseClient(), ttsQueue: queue, config: config)
    let result = try await engine.handle(text: "Testfrage", source: "test")
    try await Task.sleep(nanoseconds: 20_000_000)
    guard case .response(let answer, _) = result else {
      throw TestFailure.failed("response")
    }
    try expect(answer == "Erster Satz. Zweiter Satz.", "response text")
    try expect(
      provider.spoken == ["Erster Satz. Zweiter Satz."],
      "complete response spoken as one continuous utterance")
  }
  static func testAdapter() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockProtocol.self]
    let client = OpenWebUIClient(
      baseURL: URL(string: "https://example.test")!, auth: StaticAuth(),
      session: URLSession(configuration: config))
    MockProtocol.handler = { request in
      try expect(request.url?.path == "/api/models", "adapter endpoint")
      try expect(
        request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token", "bearer")
      return (
        200,
        Data(
          "{\"data\":[{\"id\":\"local-model\",\"info\":{\"meta\":{\"capabilities\":{\"web_search\":true,\"code_interpreter\":false},\"toolIds\":[\"calculator\"]}}}]}"
            .utf8)
      )
    }
    try await client.authenticate()
    let models = try await client.models()
    try expect(models == ["local-model"], "model parsing")
    var finalized = false
    MockProtocol.handler = { request in
      if request.url?.path == "/api/chat/completions" {
        let body = try requestJSON(request)
        let features = body["features"] as? [String: Bool]
        try expect(features?["web_search"] == true, "model web-search capability forwarded")
        try expect(body["tool_ids"] as? [String] == ["calculator"], "model tools forwarded")
        let background = body["background_tasks"] as? [String: Bool]
        try expect(background?["title_generation"] == false, "title waits for completion")
        return (
          200,
          Data(
            "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"API Antwort\"}}]}"
              .utf8)
        )
      }
      if request.url?.path == "/api/chat/completed" {
        finalized = true
        let body = try requestJSON(request)
        let background = body["background_tasks"] as? [String: Bool]
        try expect(background?["title_generation"] == true, "title starts after completion")
        return (200, Data("{\"message\":{\"role\":\"assistant\",\"content\":\"API Antwort final\"}}".utf8))
      }
      try expect(request.url?.path == "/api/v1/chats/test-chat", "chat update endpoint")
      return (200, Data("{}".utf8))
    }
    let reply = try await client.send(
      messages: [Message(role: .user, content: "Test")], chatID: "test-chat",
      model: "local-model"
    ) { _ in }
    try expect(reply == "API Antwort final", "completion outlet response parsing")
    try expect(finalized, "completion lifecycle finalized")
    MockProtocol.handler = { request in
      if request.url?.path == "/api/chat/completions" {
        return (200, Data("{\"status\":true,\"task_ids\":[\"task-1\"]}".utf8))
      }
      if request.url?.path == "/api/v1/chats/test-chat", request.httpMethod == "GET" {
        return (
          200,
          Data(
            "{\"chat\":{\"history\":{\"currentId\":\"assistant-server\",\"messages\":{\"assistant-server\":{\"id\":\"assistant-server\",\"role\":\"assistant\",\"content\":\"\",\"done\":true,\"output\":[{\"type\":\"reasoning\",\"content\":[{\"type\":\"output_text\",\"text\":\"Nicht vorlesen\"}]},{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Asynchrone Antwort\"}]}]}}}}}"
              .utf8)
        )
      }
      if request.url?.path == "/api/chat/completed" {
        return (200, Data("{}".utf8))
      }
      try expect(request.url?.path == "/api/v1/chats/test-chat", "chat update endpoint")
      return (200, Data("{}".utf8))
    }
    let asyncReply = try await client.send(
      messages: [Message(role: .user, content: "Test")], chatID: "test-chat",
      model: "local-model"
    ) { _ in }
    try expect(asyncReply == "Asynchrone Antwort", "asynchronous response polling")
  }
}

@MainActor final class RecordingTTS: TTSProvider {
  var spoken: [String] = []
  var stopped = false
  var isSpeaking = false
  func speak(_ text: String) async throws {
    isSpeaking = true
    spoken.append(text)
    try? await Task.sleep(nanoseconds: 5_000_000)
    isSpeaking = false
  }
  func stop() {
    stopped = true
    isSpeaking = false
  }
}
struct StaticAuth: AuthProvider {
  func token(baseURL: URL, session: URLSession) async throws -> String { "test-token" }
}
struct FixedResponseClient: OpenWebUIClientProtocol {
  func authenticate() async throws {}
  func health() async throws {}
  func models() async throws -> [String] { ["test-model"] }
  func createChat(title: String, messages: [Message], model: String) async throws -> String {
    "test-chat"
  }
  func send(
    messages: [Message], chatID: String, model: String,
    onToken: @escaping @Sendable (String) -> Void
  ) async throws -> String {
    onToken("Erster Satz. ")
    onToken("Zweiter Satz.")
    return "Erster Satz. Zweiter Satz."
  }
  func listChats() async throws -> [(id: String, title: String)] { [] }
  func chatURL(id: String) -> URL { URL(string: "https://example.test/c/\(id)")! }
}
final class MockProtocol: URLProtocol, @unchecked Sendable {
  static var handler: ((URLRequest) throws -> (Int, Data))?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, data) = try Self.handler?(request) ?? (500, Data())
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}
