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
      ("Config", testConfig), ("Security primitives", testSecurityPrimitives),
      ("Local HTTP parser", testLocalHTTPParser), ("Storage", testStorage),
      ("Commands", testCommands),
      ("SentenceBuffer", testSentenceBuffer), ("Speech text", testSpeechText),
      ("Dictation formatting", testDictationFormatting),
      ("HeuristicRouter continuation", testRouterContinuation),
      ("HeuristicRouter new topic", testRouterNewTopic), ("HybridRouter", testHybrid),
      ("ConversationManager", testManager), ("Confidence management", testConfidence),
      ("TTS queue/barge-in", testTTSQueue), ("Response delivery", testResponseDelivery),
      ("OpenWebUI cancellation", testResponseCancellation),
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
    c.dictation.smartFormatting = false
    c.dictation.formattingApplications = ["com.microsoft.Word", "com.example.Editor"]
    c.localLLM.enabled = true
    c.localLLM.provider = "llama_cpp"
    c.localLLM.url = "http://127.0.0.1:18881"
    c.hotkeys.dictation = "left_control"
    c.hotkeys.assistant = "right_command"
    c.tts.localCommand = "/tmp/model #1/\"voice\""
    c.stt.encoderPrecision = "int4"
    c.stt.computeMode = "fast"
    c.stt.language = "auto"
    c.stt.inputDeviceUID = "test-input-device"
    c.privacy.localCacheRetentionDays = 365
    let rendered = ConfigLoader.renderYAML(c)
    let parsed = try ConfigLoader.parseYAML(rendered)
    try expect(rendered.contains("\"schema_version\" : 1"), "configuration schema version")
    try expect(parsed.openwebui.url == "https://ai.internal", "URL round-trip")
    try expect(parsed.openwebui.tlsVerify, "TLS default")
    try expect(parsed.tts.localOnly, "local TTS")
    try expect(parsed.tts.provider == "adaptive", "adaptive German TTS default")
    try expect(parsed.spokenResponseMode == "smart_summary", "smart spoken summary default")
    try expect(parsed.spokenResponseThreshold == 850, "spoken summary threshold round-trip")
    try expect(!parsed.dictation.polishWithLocalAI, "dictation polishing round-trip")
    try expect(!parsed.dictation.smartFormatting, "dictation formatting round-trip")
    try expect(
      parsed.dictation.formattingApplications == ["com.microsoft.Word", "com.example.Editor"],
      "dictation formatting applications round-trip")
    try expect(
      parsed.localLLM.enabled && parsed.localLLM.provider == "llama_cpp"
        && parsed.localLLM.url == "http://127.0.0.1:18881",
      "llama.cpp intelligence round-trip")
    try expect(
      LocalLLMEndpoint.completionsURL(from: URL(string: "http://127.0.0.1:18881")!).absoluteString
        == "http://127.0.0.1:18881/v1/chat/completions",
      "llama.cpp completion endpoint")
    try expect(
      LocalLLMEndpoint.modelsURL(from: URL(string: "http://127.0.0.1:11434/v1")!).absoluteString
        == "http://127.0.0.1:11434/v1/models",
      "Ollama v1 endpoint normalization")
    let routed = try JSONDecoder().decode(
      RoutingDecision.self,
      from: Data(
        #"{"decision":"switch_chat","chat_id":"abc","confidence":0.9,"reason":"match"}"#.utf8))
    try expect(routed.chatID == "abc", "local router snake-case chat ID")
    try expect(
      parsed.hotkeys.dictation == "left_control" && parsed.hotkeys.assistant == "right_command",
      "activation keys round-trip")
    try expect(parsed.tts.localCommand == c.tts.localCommand, "escaped value round-trip")
    try expect(
      parsed.stt.encoderPrecision == "int4" && parsed.stt.computeMode == "fast"
        && parsed.stt.language == "auto" && parsed.stt.inputDeviceUID == "test-input-device",
      "STT settings round-trip")
    try expect(parsed.privacy.localCacheRetentionDays == 365, "cache retention round-trip")
    try expect(AppConfig().api.tokenRequired, "secure API default")
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
    var unsafeConfig = c
    unsafeConfig.api.bind = "0.0.0.0"
    do {
      _ = try ConfigLoader.parseYAML(ConfigLoader.renderYAML(unsafeConfig))
      throw TestFailure.failed("unsafe listener accepted")
    } catch is MiddleAIError {}
    var conflictingConfig = c
    conflictingConfig.hotkeys.assistant = conflictingConfig.hotkeys.dictation
    do {
      _ = try ConfigLoader.parseYAML(ConfigLoader.renderYAML(conflictingConfig))
      throw TestFailure.failed("conflicting activation keys accepted")
    } catch is MiddleAIError {}

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let legacyURL = directory.appendingPathComponent("config.yaml")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let legacy = """
      openwebui:
        url: "https://ai.example/path#fragment"
        model: "model:one"
      tts:
        local_only: true
      hotkeys:
        dictation: "left_option"
        assistant: "right_option"
      api:
        bind: "127.0.0.1"
        token_required: false
      """
    try Data(legacy.utf8).write(to: legacyURL)
    let migrated = try ConfigLoader.load(from: legacyURL)
    try expect(migrated.openwebui.url.hasSuffix("#fragment"), "quoted legacy comment migration")
    try expect(!migrated.api.tokenRequired, "legacy API authentication compatibility")
    let migratedText = try String(contentsOf: legacyURL, encoding: .utf8)
    try expect(migratedText.contains("\"schema_version\""), "legacy configuration rewritten")
    try expect(
      FileManager.default.fileExists(
        atPath: legacyURL.appendingPathExtension("legacy-backup").path),
      "legacy configuration backup")
    let mode =
      try FileManager.default.attributesOfItem(atPath: legacyURL.path)[.posixPermissions]
      as? NSNumber
    try expect((mode?.intValue ?? 0) & 0o777 == 0o600, "configuration file permissions")

    do {
      _ = try ConfigLoader.parseYAML("api:\n  token_required: perhaps\n")
      throw TestFailure.failed("invalid legacy boolean accepted")
    } catch is MiddleAIError {}
  }

  @MainActor static func testSecurityPrimitives() async throws {
    let base = MemoryCredentialStore()
    try base.save("first", account: "password")
    let serverA = ScopedCredentialStore(
      base: base, baseURL: "https://AI.example/", profile: "Default")
    let serverB = ScopedCredentialStore(
      base: base, baseURL: "https://other.example", profile: "default")
    let first = try serverA.read(account: "password")
    let removedLegacy = try base.read(account: "password")
    let persisted = try base.read(account: serverA.scopedAccount(for: "password"))
    try expect(first == "first", "legacy credential migration")
    try expect(removedLegacy == nil, "legacy credential removed")
    try expect(
      persisted == "first", "scoped credential persisted")
    try base.save("updated", account: "password")
    let updated = try serverA.read(account: "password")
    let isolated = try serverB.read(account: "password")
    try expect(updated == "updated", "legacy UI update migrated")
    try expect(isolated == nil, "server credentials isolated")
    try base.save("second-server", account: "password")
    let second = try serverB.read(account: "password")
    let retained = try serverA.read(account: "password")
    try expect(second == "second-server", "second scope migrated")
    try expect(retained == "updated", "first scope retained")

    let localToken = try LocalInputServer.ensureLocalAPIToken(in: base)
    let repeatedToken = try LocalInputServer.ensureLocalAPIToken(in: base)
    let unrelatedAPIToken = try base.read(account: "api_token")
    try expect(
      localToken.count >= 40 && repeatedToken == localToken, "stable random local API token")
    try expect(
      unrelatedAPIToken == nil,
      "local and OpenWebUI API tokens use separate accounts")

    let safe = MiddleAILogger.sanitizedMetadata([
      "source": "voice-assistant", "latency_ms": "42", "email": "person@example.test",
      "prompt": "secret", "request_id": "invalid value with spaces",
    ])
    try expect(safe == ["source": "voice-assistant", "latency_ms": "42"], "log allow-list")
  }

  static func testLocalHTTPParser() async throws {
    let body = Data(#"{"text":"Hallo"}"#.utf8)
    let request =
      Data(
        "POST /input HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
      + body
    switch LocalHTTPRequest.parse(request) {
    case .complete(let parsed):
      try expect(parsed.method == "POST" && parsed.path == "/input", "HTTP request line")
      try expect(parsed.body == body, "HTTP body")
    default: throw TestFailure.failed("valid local HTTP request rejected")
    }
    let partial = request.dropLast()
    if case .incomplete = LocalHTTPRequest.parse(Data(partial)) {
    } else {
      throw TestFailure.failed("partial HTTP request accepted")
    }
    if case .tooLarge(.header) = LocalHTTPRequest.parse(
      Data(repeating: 65, count: 20), maximumHeaderBytes: 16, maximumBodyBytes: 100)
    {
    } else {
      throw TestFailure.failed("oversized HTTP header accepted")
    }
    let oversized = Data("POST /input HTTP/1.1\r\nContent-Length: 5\r\n\r\n12345".utf8)
    if case .tooLarge(.body) = LocalHTTPRequest.parse(
      oversized, maximumHeaderBytes: 100, maximumBodyBytes: 4)
    {
    } else {
      throw TestFailure.failed("oversized HTTP body accepted")
    }
    let duplicate = Data(
      "GET /health HTTP/1.1\r\nHost: one\r\nHost: two\r\n\r\n".utf8)
    if case .invalid = LocalHTTPRequest.parse(duplicate) {
    } else {
      throw TestFailure.failed("duplicate HTTP header accepted")
    }
    let chunked = Data(
      "POST /input HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
    if case .invalid = LocalHTTPRequest.parse(chunked) {
    } else {
      throw TestFailure.failed("chunked HTTP body accepted")
    }
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
    try expect(
      savedConversation?.openWebUIBaseURL == "https://ai.example", "remote scope persistence")
    try expect(savedMessages.first?.content == "Gardena", "message persistence")
    let mode =
      try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
      as? NSNumber
    try expect((mode?.intValue ?? 0) & 0o777 == 0o600, "SQLite file permissions")
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
    try expect(
      !grouped.contains("1.250.000") && grouped.contains("Million"), "grouped number spelling")
    let segments = SpeechTextProcessor.segments(
      for: "Der Python Workflow verarbeitet 3,5 Millionen Datensätze.")
    try expect(
      segments.contains(where: { $0.language == .english && $0.text.contains("Python") }),
      "English pronunciation segment")
    try expect(
      segments.contains(where: { $0.language == .german && $0.text.contains("drei Komma fünf") }),
      "German number segment")
    let prepared = SpeechTextProcessor.speechReadyGermanText(
      "**Python Workflow:** 3,5 Millionen Datensätze")
    try expect(
      !prepared.contains("**") && prepared.contains("Peiton Wörkfloh"),
      "continuous German pronunciation preparation")
    try expect(
      SpeechTextProcessor.prefersPreciseGermanVoice("Das Ergebnis beträgt 3,5 Millionen."),
      "numbers prefer precise German voice")
    try expect(
      SpokenResponseSummarizer.plainText("## Ergebnis\n- **Wichtig**") == "Ergebnis. Wichtig",
      "spoken Markdown cleanup")
    let researchSummary = SpokenResponseSummarizer.extractiveSummary(
      "Die Recherche umfasst fünf Märkte und zahlreiche Quellen. Der erste Markt wächst moderat. "
        + "Mehrere Anbieter investieren in Automatisierung. Ein Risiko bleibt die Regulierung. "
        + "Das wichtigste Ergebnis: Der deutsche Markt dürfte bis 2028 um 18 Prozent wachsen. "
        + "Als nächster Schritt empfiehlt sich ein Pilotprojekt mit klarer Erfolgsmessung.",
      maximumWords: 70)
    try expect(
      researchSummary.contains("wichtigste Ergebnis")
        && researchSummary.contains("nächster Schritt")
        && researchSummary.components(separatedBy: ".").count > 2,
      "research response is summarized beyond its first paragraph: \(researchSummary)")
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
  static func testDictationFormatting() async throws {
    let paragraphs = DictationFormatter.format(
      "Hallo neue Zeile Sebastian neuer Absatz Viele Grüße")
    try expect(
      paragraphs.plainText == "Hallo\nSebastian\n\nViele Grüße",
      "spoken line and paragraph commands")
    try expect(
      paragraphs.html.contains("<br>") && paragraphs.html.contains("<p>"), "HTML paragraphs")

    let quote = DictationFormatter.format(
      "Das Projekt heißt in Anführungsstrichen Apollo.")
    try expect(quote.plainText == "Das Projekt heißt „Apollo“.", "spoken inline quotes")

    let bullets = DictationFormatter.format(
      "Aufzählung Punkt eins Analyse nächster Punkt Umsetzung Liste Ende")
    try expect(
      bullets.plainText == "• Analyse\n• Umsetzung" && bullets.html.contains("<ul>"),
      "spoken bullet list: \(bullets.plainText)")

    let numbered = DictationFormatter.format(
      "Nummerierte Liste Punkt eins Recherche nächster Punkt Entscheidung Liste Ende")
    try expect(
      numbered.plainText == "1. Recherche\n2. Entscheidung" && numbered.html.contains("<ol>"),
      "spoken numbered list")

    let naturalEnumeration = DictationFormatter.format(
      "Hierfür folgende Aufzählungspunkte. Aufzählung: 1. KI-Innovation, zweitens Datenklassifizierung und drittens Backup-Konzept."
    )
    try expect(
      naturalEnumeration.plainText
        == "Hierfür folgende Aufzählungspunkte.\n\n• KI-Innovation\n• Datenklassifizierung\n• Backup-Konzept.",
      "number and ordinal list markers: \(naturalEnumeration.plainText)")
    try expect(naturalEnumeration.html.contains("<ul>"), "natural enumeration HTML list")

    let multipleLists = DictationFormatter.format(
      "Aufzählung Punkt eins Analyse Punkt zwei Umsetzung Liste Ende neuer Absatz "
        + "Aufzählung Punkt eins Test Punkt zwei Freigabe Liste Ende")
    try expect(
      multipleLists.plainText.contains("• Analyse\n• Umsetzung")
        && multipleLists.plainText.contains("• Test\n• Freigabe"),
      "multiple spoken lists: \(multipleLists.plainText)")

    let punctuation = DictationFormatter.format(
      "Hallo Komma Sebastian Doppelpunkt alles gut Fragezeichen")
    try expect(
      punctuation.plainText == "Hallo, Sebastian: alles gut?",
      "explicit punctuation commands")

    let ordinary = DictationFormatter.format("Die neue Zeile ist rot.")
    try expect(
      !ordinary.didApplyFormatting && ordinary.plainText == "Die neue Zeile ist rot.",
      "ordinary wording is preserved")
    let literalPunctuation = DictationFormatter.format("Das Wort Komma ist ein Substantiv.")
    try expect(
      !literalPunctuation.didApplyFormatting
        && literalPunctuation.plainText == "Das Wort Komma ist ein Substantiv.",
      "literal punctuation word is preserved")
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
  @MainActor static func testResponseCancellation() async throws {
    let queue = TTSQueue(provider: RecordingTTS())
    let manager = ConversationManager(
      store: InMemoryConversationStore(),
      router: FixedRouter(
        result: RoutingDecision(decision: .newChat, confidence: 0.9, reason: "test")))
    var config = AppConfig()
    config.openwebui.model = "test-model"
    let client = SlowResponseClient()
    let engine = MiddleAIEngine(
      manager: manager, client: client, ttsQueue: queue, config: config)
    let request = Task { try await engine.handle(text: "Lange Frage", source: "test") }
    try await Task.sleep(for: .milliseconds(20))
    engine.interrupt()
    do {
      _ = try await request.value
      throw TestFailure.failed("active OpenWebUI request was not cancelled")
    } catch is CancellationError {
      // Expected: interrupting the engine cancels the network generation, not just speech.
    }
    try await Task.sleep(for: .milliseconds(20))
    try expect(client.cancelledChatID == "test-chat", "OpenWebUI background task stopped")
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
    let streamedTokens = LockedTokens()
    MockProtocol.handler = { request in
      if request.url?.path == "/api/chat/completions" {
        let body = try requestJSON(request)
        try expect(body["stream"] as? Bool == true, "streaming requested")
        let features = body["features"] as? [String: Bool]
        try expect(features?["web_search"] == true, "model web-search capability forwarded")
        try expect(body["tool_ids"] as? [String] == ["calculator"], "model tools forwarded")
        let background = body["background_tasks"] as? [String: Bool]
        try expect(background?["title_generation"] == false, "title waits for completion")
        return (
          200,
          Data(
            "data: {\"choices\":[{\"delta\":{\"content\":\"API \"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"Antwort\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
              .utf8)
        )
      }
      if request.url?.path == "/api/chat/completed" {
        finalized = true
        let body = try requestJSON(request)
        let background = body["background_tasks"] as? [String: Bool]
        try expect(background?["title_generation"] == true, "title starts after completion")
        return (
          200, Data("{\"message\":{\"role\":\"assistant\",\"content\":\"API Antwort final\"}}".utf8)
        )
      }
      try expect(request.url?.path == "/api/v1/chats/test-chat", "chat update endpoint")
      return (200, Data("{}".utf8))
    }
    let reply = try await client.send(
      messages: [Message(role: .user, content: "Test")], chatID: "test-chat",
      model: "local-model"
    ) { streamedTokens.append($0) }
    try expect(reply == "API Antwort final", "completion outlet response parsing")
    try expect(streamedTokens.values == ["API ", "Antwort"], "SSE tokens delivered incrementally")
    try expect(finalized, "completion lifecycle finalized")
    let asyncTokens = LockedTokens()
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
    ) { asyncTokens.append($0) }
    try expect(asyncReply == "Asynchrone Antwort", "asynchronous response polling")
    try expect(
      asyncTokens.values == ["Asynchrone Antwort"], "polled response delivered incrementally")

    let fallbackTokens = LockedTokens()
    let completionAttempts = LockedCounter()
    MockProtocol.handler = { request in
      if request.url?.path == "/api/chat/completions" {
        let attempt = completionAttempts.increment()
        let body = try requestJSON(request)
        if attempt == 1 {
          try expect(body["stream"] as? Bool == true, "stream tried before fallback")
          return (422, Data("{\"detail\":\"stream unsupported\"}".utf8))
        }
        try expect(body["stream"] as? Bool == false, "non-streaming compatibility fallback")
        return (
          200,
          Data(
            "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"Fallback Antwort\"}}]}"
              .utf8)
        )
      }
      if request.url?.path == "/api/chat/completed" { return (200, Data("{}".utf8)) }
      return (200, Data("{}".utf8))
    }
    let fallbackReply = try await client.send(
      messages: [Message(role: .user, content: "Test")], chatID: "test-chat",
      model: "local-model"
    ) { fallbackTokens.append($0) }
    try expect(fallbackReply == "Fallback Antwort", "non-streaming fallback response")
    try expect(fallbackTokens.values == ["Fallback Antwort"], "fallback content delivered once")
    try expect(completionAttempts.value == 2, "streaming rejection retried exactly once")
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
final class SlowResponseClient: OpenWebUIClientProtocol, @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled: String?
  var cancelledChatID: String? { lock.withLock { cancelled } }
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
    try await Task.sleep(for: .seconds(30))
    return "unexpected"
  }
  func cancel(chatID: String) async {
    lock.withLock { cancelled = chatID }
  }
  func listChats() async throws -> [(id: String, title: String)] { [] }
  func chatURL(id: String) -> URL { URL(string: "https://example.test/c/\(id)")! }
}
final class LockedTokens: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []
  var values: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
  func append(_ token: String) {
    lock.lock()
    storage.append(token)
    lock.unlock()
  }
}
final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
  func increment() -> Int {
    lock.lock()
    defer { lock.unlock() }
    storage += 1
    return storage
  }
}
final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: String] = [:]
  func save(_ value: String, account: String) throws {
    lock.lock()
    values[account] = value
    lock.unlock()
  }
  func read(account: String) throws -> String? {
    lock.lock()
    defer { lock.unlock() }
    return values[account]
  }
  func delete(account: String) throws {
    lock.lock()
    values.removeValue(forKey: account)
    lock.unlock()
  }
}
final class MockProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
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
