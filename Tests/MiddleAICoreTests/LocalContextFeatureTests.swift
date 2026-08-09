import Foundation
import XCTest

@testable import MiddleAICore

final class LocalContextFeatureTests: XCTestCase {
  func testExplicitKnowledgeGrantIndexesSearchesAndPersistsCitations() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let documents = directory.appendingPathComponent("Freigabe", isDirectory: true)
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    let content = """
      Projekt Aurora
      Die Kündigungsfrist beträgt sechs Monate zum Jahresende.
      Der Ansprechpartner ist Lara Beispiel.
      """
    try content.write(
      to: documents.appendingPathComponent("Vertrag.md"), atomically: true, encoding: .utf8)
    try "SECRET=should-not-be-read".write(
      to: documents.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

    let database = directory.appendingPathComponent("context.sqlite").path
    let store = try SQLiteLocalContextStore(path: database)
    let knowledge = LocalKnowledgeBase(store: store)
    let source = try await knowledge.grant(url: documents)
    let report = try await knowledge.index(sourceID: source.id)

    XCTAssertEqual(report.indexedFiles, 1)
    XCTAssertGreaterThanOrEqual(report.indexedChunks, 1)
    let hits = try await knowledge.search("Welche Kündigungsfrist gilt für Aurora?")
    XCTAssertEqual(hits.first?.relativePath, "Vertrag.md")
    XCTAssertTrue(hits.first?.excerpt.contains("sechs Monate") == true)
    XCTAssertTrue(hits.first?.citation.contains("Zeile") == true)
    let context = try await knowledge.context(for: "Kündigungsfrist")
    XCTAssertFalse(context.contains("SECRET"))

    let reopened = try SQLiteLocalContextStore(path: database)
    let reopenedKnowledge = LocalKnowledgeBase(store: reopened)
    let reopenedHits = try await reopenedKnowledge.search("Lara")
    XCTAssertEqual(reopenedHits.first?.sourceID, source.id)
  }

  func testKnowledgePolicyRejectsBroadHiddenAndSymlinkGrants() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let hidden = directory.appendingPathComponent(".private", isDirectory: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
    let target = directory.appendingPathComponent("plain.txt")
    try "Inhalt".write(to: target, atomically: true, encoding: .utf8)
    let link = directory.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let store = try SQLiteLocalContextStore(
      path: directory.appendingPathComponent("context.sqlite").path)
    let knowledge = LocalKnowledgeBase(store: store)

    do {
      _ = try await knowledge.grant(url: hidden)
      XCTFail("Hidden source must be rejected")
    } catch {}
    do {
      _ = try await knowledge.grant(url: link)
      XCTFail("Symlink source must be rejected")
    } catch {}
  }

  func testProfileMemoriesAreExplicitScopedEditableExpiringAndDeletable() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SQLiteLocalContextStore(
      path: directory.appendingPathComponent("context.sqlite").path)
    let memories = ProfileMemoryService(store: store)
    let now = Date(timeIntervalSince1970: 10_000)
    let item = try await memories.create(
      profile: "research", key: "Antwortstil", value: "Quellen knapp benennen",
      expiresAt: now.addingTimeInterval(60), now: now)
    _ = try await memories.create(
      profile: "coding", key: "Sprache", value: "Swift", now: now)

    let researchMemories = try await memories.memories(profile: "research", now: now)
    XCTAssertEqual(researchMemories.count, 1)
    let researchContext = try await memories.context(
      profile: "research", matching: "Quellen", now: now)
    XCTAssertFalse(researchContext.contains("Swift"))
    let updated = try await memories.update(
      id: item.id, key: "Antwortstil", value: "Quellen mit Datum benennen",
      expiresAt: now.addingTimeInterval(120), now: now.addingTimeInterval(1))
    XCTAssertEqual(updated.value, "Quellen mit Datum benennen")
    let expired = try await memories.memory(id: updated.id, now: now.addingTimeInterval(121))
    XCTAssertNil(expired)
    let purged = try await memories.purgeExpired(now: now.addingTimeInterval(121))
    XCTAssertEqual(purged, 1)

    let coding = try await memories.memories(profile: "coding", now: now)
    try await memories.delete(id: try XCTUnwrap(coding.first?.id))
    let remainingCoding = try await memories.memories(profile: "coding", now: now)
    XCTAssertTrue(remainingCoding.isEmpty)
  }

  func testTextTransformationReturnsPreviewWithoutApplyingIt() async throws {
    let assistant = TextTransformationAssistant(
      generator: StubTextGenerator(output: "Das ist ein sachlicher Test mit 3,5 Millionen Euro."))
    let result = try await assistant.preview(
      TextTransformationRequest(
        selectedText: "Das ist äh ein sachlicher Test mit 3,5 Millionen Euro.", action: .polish))

    XCTAssertTrue(result.changed)
    XCTAssertEqual(result.originalText, "Das ist äh ein sachlicher Test mit 3,5 Millionen Euro.")
    XCTAssertEqual(result.transformedText, "Das ist ein sachlicher Test mit 3,5 Millionen Euro.")
  }

  func testCorrectAndPolishRejectUngroundedReplacement() async throws {
    let assistant = TextTransformationAssistant(
      generator: StubTextGenerator(output: "Eine vollständig andere Aussage über das Wetter."))
    do {
      _ = try await assistant.preview(
        TextTransformationRequest(
          selectedText: "Der Vertrag endet am 31. Dezember und kostet 8.000 Euro.",
          action: .correct))
      XCTFail("Ungrounded correction must be rejected")
    } catch {}
  }

  func testTextGeneratorRejectsNonLoopbackEndpoint() {
    XCTAssertThrowsError(
      try OpenAICompatibleLocalTextGenerator(
        endpoint: URL(string: "http://example.com:18881")!, model: "model"))
  }

  private func temporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "middleai-context-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}

private struct StubTextGenerator: LocalTextGenerationProtocol {
  let output: String
  func complete(systemPrompt: String, userPrompt: String) async throws -> String { output }
}
