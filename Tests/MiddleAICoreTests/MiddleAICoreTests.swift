import Foundation
import XCTest

@testable import MiddleAICore

final class MiddleAICoreTests: XCTestCase {
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
