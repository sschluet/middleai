import Foundation
import XCTest

@testable import MiddleAICore

final class MiddleAICoreTests: XCTestCase {
  func testImmediateFollowUpContinuesCurrentConversation() async throws {
    let now = Date()
    let conversation = Conversation(
      title: "Photosynthese", summary: "Pflanzen wandeln Licht in Energie um",
      lastUsedAt: now.addingTimeInterval(-30))
    let context = ConversationContext(
      input: "Warum ist das für Pflanzen wichtig?", current: conversation,
      recent: [conversation], messages: [:], now: now)

    let heuristic = try await HeuristicRouter().route(context)
    let hybrid = try await HybridRouter(heuristic: HeuristicRouter()).route(context)

    XCTAssertEqual(heuristic.decision, .continueCurrent)
    XCTAssertEqual(hybrid.decision, .continueCurrent)
    XCTAssertEqual(hybrid.chatID, conversation.id)
  }

  func testExplicitTopicChangeStartsNewConversation() async throws {
    let now = Date()
    let conversation = Conversation(
      title: "Photosynthese", summary: "Pflanzen", lastUsedAt: now)
    let decision = try await HeuristicRouter().route(
      ConversationContext(
        input: "Andere Frage: Wie hoch ist der Eiffelturm?", current: conversation,
        recent: [conversation], messages: [:], now: now))

    XCTAssertEqual(decision.decision, .newChat)
  }

  func testPrivacyRetentionRoundTrip() throws {
    var config = AppConfig()
    config.privacy.localCacheRetentionDays = 365
    let parsed = try ConfigLoader.parseYAML(ConfigLoader.renderYAML(config))
    XCTAssertEqual(parsed.privacy.localCacheRetentionDays, 365)
  }

  func testSTTSettingsRoundTrip() throws {
    var config = AppConfig()
    config.stt.language = "auto"
    config.stt.encoderPrecision = "int4"
    config.stt.computeMode = "fast"
    config.stt.longFormMode = "fast"
    config.stt.inputDeviceUID = "test-input-device"
    let parsed = try ConfigLoader.parseYAML(ConfigLoader.renderYAML(config))
    XCTAssertEqual(parsed.stt, config.stt)
  }

  func testHostedProviderAndAudioOutputRoundTrip() throws {
    var config = AppConfig()
    config.assistant.provider = "openai"
    config.openai.model = "gpt-5.6-terra"
    config.tts.outputDeviceUID = "speaker-uid"
    let parsed = try ConfigLoader.parseYAML(ConfigLoader.renderYAML(config))
    XCTAssertEqual(parsed.assistant.provider, "openai")
    XCTAssertEqual(parsed.assistantModel, "gpt-5.6-terra")
    XCTAssertEqual(parsed.tts.outputDeviceUID, "speaker-uid")
  }

  func testProfileSystemPromptsRoundTrip() throws {
    var config = AppConfig()
    config.activeProfile = "research"
    config.profiles.systemPrompts["research"] = "Prüfe jede Quelle und benenne Unsicherheiten."
    let parsed = try ConfigLoader.parseYAML(ConfigLoader.renderYAML(config))
    XCTAssertEqual(parsed.activeProfile, "research")
    XCTAssertEqual(
      parsed.profileSystemPrompt(for: "research"),
      "Prüfe jede Quelle und benenne Unsicherheiten.")
  }

  func testProfileOverridesAreResolvedWithoutMutatingGlobalDefaults() throws {
    var config = AppConfig()
    config.activeProfile = "research"
    config.openwebui.model = "global-model"
    config.tts.voice = "global-voice"
    config.profiles.overrides["research"] = AppConfig.ProfileOverrides(
      assistantProvider: "openrouter", model: "profile-model", ttsVoice: "profile-voice",
      spokenResponseMode: "first_paragraph", contextBudgetCharacters: 12_000)

    let parsed = try ConfigLoader.parseYAML(ConfigLoader.renderYAML(config))
    let resolved = parsed.resolved()

    XCTAssertEqual(resolved.assistant.provider, "openrouter")
    XCTAssertEqual(resolved.openrouter.model, "profile-model")
    XCTAssertEqual(resolved.tts.voice, "profile-voice")
    XCTAssertEqual(resolved.spokenResponseMode, "first_paragraph")
    XCTAssertEqual(resolved.activeContextBudgetCharacters, 12_000)
    XCTAssertEqual(parsed.assistant.provider, "openwebui")
    XCTAssertEqual(parsed.openwebui.model, "global-model")
    XCTAssertEqual(parsed.tts.voice, "global-voice")
  }

  func testConfigurationRejectsUnsafeLocalLLMAndInvalidProfileOverrides() throws {
    var remoteLLM = AppConfig()
    remoteLLM.localLLM.enabled = true
    remoteLLM.localLLM.provider = "llama_cpp"
    remoteLLM.localLLM.url = "http://example.com:18881"
    XCTAssertThrowsError(try ConfigLoader.parseYAML(ConfigLoader.renderYAML(remoteLLM)))

    var invalidProfile = AppConfig()
    invalidProfile.profiles.overrides["coding"] = AppConfig.ProfileOverrides(
      contextBudgetCharacters: 3_999)
    XCTAssertThrowsError(try ConfigLoader.parseYAML(ConfigLoader.renderYAML(invalidProfile)))
  }

  func testSupportReportOmitsSecretsAndFailedDetails() {
    let report = SupportBundleBuilder.report(
      environment: SupportBundleEnvironment(
        appVersion: "1.0", operatingSystem: "macOS", architecture: "arm64",
        assistantProvider: "OpenWebUI", ttsProvider: "macOS", activeProfile: "default",
        privateSession: true),
      checks: [
        DiagnosticCheck(name: "Verbindung", passed: false, detail: "https://secret.example/user"),
        DiagnosticCheck(name: "Dateirechte", passed: true, detail: "600; erwartet 600"),
      ],
      localModelStates: [(name: "TTS", state: "bereit", size: "1 GB")])

    XCTAssertTrue(report.contains("Private Sitzung: aktiv"))
    XCTAssertTrue(report.contains("600; erwartet 600"))
    XCTAssertFalse(report.contains("secret.example"))
  }

  func testResearchFallbackSelectsConclusionsAndNextSteps() {
    let response =
      "Die Recherche umfasst fünf Märkte und zahlreiche Quellen. "
      + "Der erste Markt wächst moderat. Mehrere Anbieter investieren in Automatisierung. "
      + "Ein Risiko bleibt die Regulierung. "
      + "Das wichtigste Ergebnis: Der deutsche Markt dürfte bis 2028 um 18 Prozent wachsen. "
      + "Als nächster Schritt empfiehlt sich ein Pilotprojekt mit klarer Erfolgsmessung."
    let summary = SpokenResponseSummarizer.extractiveSummary(response, maximumWords: 70)
    XCTAssertTrue(summary.contains("wichtigste Ergebnis"))
    XCTAssertTrue(summary.contains("nächster Schritt"))
    XCTAssertGreaterThan(summary.components(separatedBy: ".").count, 2)
  }

  func testSpokenSummaryNeverEndsMidSentence() {
    let longSentence = Array(repeating: "ausführlicher Inhalt", count: 250).joined(separator: " ")
    let summary = SpokenResponseSummarizer.extractiveSummary(
      longSentence, maximumWords: 40)

    XCTAssertTrue(summary.hasSuffix("Die vollständige Antwort ist in MiddleAI sichtbar."))
  }

  func testConversationCacheCanBeInspectedPurgedAndCleared() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "middleai-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SQLiteConversationStore(
      path: directory.appendingPathComponent("cache.sqlite").path)

    let old = Conversation(
      title: "Alt", createdAt: Date(timeIntervalSince1970: 1),
      lastUsedAt: Date(timeIntervalSince1970: 1))
    let current = Conversation(title: "Aktuell")
    try store.saveConversation(old)
    try store.saveConversation(current)
    try store.saveMessage(Message(role: .user, content: "Alt"), conversationID: old.id)
    try store.saveMessage(Message(role: .user, content: "Neu"), conversationID: current.id)

    XCTAssertEqual(
      try store.cacheStatistics(), ConversationCacheStatistics(conversations: 2, messages: 2))
    try store.deleteConversations(lastUsedBefore: Date(timeIntervalSince1970: 2))
    XCTAssertEqual(
      try store.cacheStatistics(), ConversationCacheStatistics(conversations: 1, messages: 1))
    try store.deleteAllConversations()
    XCTAssertEqual(
      try store.cacheStatistics(), ConversationCacheStatistics(conversations: 0, messages: 0))
  }

  func testConversationExchangePersistsBothSidesAndMetadataTogether() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "middleai-exchange-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SQLiteConversationStore(
      path: directory.appendingPathComponent("cache.sqlite").path)
    var conversation = Conversation(title: "Atomic")
    try store.saveConversation(conversation)
    conversation.summary = "Complete"
    let user = Message(role: .user, content: "Frage")
    let assistant = Message(role: .assistant, content: "Antwort")

    try store.saveExchange(user: user, assistant: assistant, conversation: conversation)

    let messages = try store.messages(conversationID: conversation.id, limit: 10)
    XCTAssertEqual(messages.map(\.id), [user.id, assistant.id])
    XCTAssertEqual(messages.map(\.role), [.user, .assistant])
    XCTAssertEqual(messages.map(\.content), ["Frage", "Antwort"])
    XCTAssertEqual(try store.conversation(id: conversation.id)?.summary, "Complete")
    XCTAssertEqual(try store.setting(key: "current_conversation_id"), conversation.id)
  }

  func testHostedContextWindowRetainsSystemAndNewestTurnWithinBudget() {
    let messages =
      [Message(role: .system, content: "Systemregeln")]
      + (0..<30).map { index in
        Message(
          role: index.isMultiple(of: 2) ? .user : .assistant,
          content: "Nachricht \(index) " + String(repeating: "Inhalt ", count: 80))
      }

    let prepared = HostedContextWindow.prepared(messages, maximumEstimatedTokens: 700)

    XCTAssertLessThanOrEqual(HostedContextWindow.estimatedTokens(prepared), 700)
    XCTAssertEqual(prepared.first?.role, .system)
    XCTAssertTrue(prepared.last?.content.contains("Nachricht 29") == true)
    XCTAssertTrue(prepared.contains { $0.content.contains("Lokale Zusammenfassung") })
  }

  func testMultipleSpokenListsAndLiteralCommands() {
    let result = DictationFormatter.format(
      "Aufzählung: Punkt eins Äpfel, Punkt zwei Birnen, Liste Ende. Danach neuer Absatz "
        + "nummerierte Liste: erstens Planen, zweitens Umsetzen, Liste Ende.")
    XCTAssertTrue(result.didApplyFormatting)
    XCTAssertTrue(result.plainText.contains("• Äpfel\n• Birnen"))
    XCTAssertTrue(result.plainText.contains("1. Planen\n2. Umsetzen"))
    XCTAssertTrue(result.html.contains("<ul>"))
    XCTAssertTrue(result.html.contains("<ol>"))

    let literal = DictationFormatter.format("Das Wort Komma ist ein Substantiv.")
    XCTAssertEqual(literal.plainText, "Das Wort Komma ist ein Substantiv.")
    XCTAssertFalse(literal.didApplyFormatting)
  }
}
