import Foundation
import MiddleAICore

enum LocalFeatureRegressionTests {
  static func testLocalRuntime() async throws {
    var local = AppConfig()
    local.assistant.provider = "local"
    local.localLLM.enabled = true
    local.localLLM.provider = "llama_cpp"
    local.localLLM.url = "http://127.0.0.1:18881"
    local.localLLM.model = "local-test"
    local.privacy.strictOffline = true
    let decoded = try ConfigLoader.parseYAML(ConfigLoader.renderYAML(local))
    try expect(decoded.assistantProviderTitle == "MiddleAI Lokal", "local provider title")
    try expect(decoded.assistantModel == "local-test", "local provider model")
    try expect(
      NetworkAccessPolicy.isLoopback(URL(string: "http://127.0.0.1:18881")!),
      "loopback policy")
    try expect(
      !NetworkAccessPolicy.isLoopback(URL(string: "https://api.openai.com/v1")!),
      "remote policy")

    var hosted = AppConfig()
    hosted.assistant.provider = "openai"
    hosted.openai.model = "hosted"
    hosted.privacy.strictOffline = true
    do {
      _ = try ConfigLoader.parseYAML(ConfigLoader.renderYAML(hosted))
      throw TestFailure.failed("strict offline accepted hosted provider")
    } catch is TestFailure {
      throw TestFailure.failed("strict offline accepted hosted provider")
    } catch {}

    let scheduler = InferenceScheduler(maximumConcurrentOperations: 1)
    let value = try await scheduler.run(workload: .languageModel) { "fertig" }
    let snapshot = await scheduler.snapshot()
    try expect(
      value == "fertig" && snapshot.active.isEmpty && snapshot.queued.isEmpty,
      "inference scheduler release")
    let resources = LocalRuntimeResources(
      physicalMemoryBytes: 24 * 1_073_741_824, availableDiskBytes: nil,
      processorCount: 10, activeProcessorCount: 10)
    try expect(resources.recommendedMaximumModelBillions == 14, "model size recommendation")
  }

  static func testLocalContext() async throws {
    let directory = temporaryDirectory("context")
    defer { try? FileManager.default.removeItem(at: directory) }
    let documents = directory.appendingPathComponent("Freigabe", isDirectory: true)
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    try "Projekt Aurora\nDie Kündigungsfrist beträgt sechs Monate zum Jahresende."
      .write(to: documents.appendingPathComponent("Vertrag.md"), atomically: true, encoding: .utf8)
    try "SECRET=ignored".write(
      to: documents.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

    let store = try SQLiteLocalContextStore(
      path: directory.appendingPathComponent("context.sqlite").path)
    let knowledge = LocalKnowledgeBase(store: store)
    let source = try await knowledge.grant(url: documents)
    let report = try await knowledge.index(sourceID: source.id)
    let hits = try await knowledge.search("Welche Kündigungsfrist gilt?")
    try expect(report.indexedFiles == 1 && report.indexedChunks >= 1, "knowledge indexing")
    try expect(hits.first?.excerpt.contains("sechs Monate") == true, "knowledge retrieval")
    let knowledgeContext = try await knowledge.context(for: "Kündigungsfrist")
    try expect(!knowledgeContext.contains("SECRET"), "knowledge secret exclusion")

    let memories = ProfileMemoryService(store: store)
    let memory = try await memories.create(
      profile: "research", key: "Antwortstil", value: "Quellen knapp benennen")
    let memoryContext = try await memories.context(profile: "research", matching: "Quellen")
    try expect(memoryContext.contains("Quellen knapp"), "profile memory retrieval")
    try await memories.delete(id: memory.id)
    let remainingMemories = try await memories.memories(profile: "research")
    try expect(remainingMemories.isEmpty, "profile memory delete")
  }

  static func testLocalTextTransformation() async throws {
    let assistant = TextTransformationAssistant(
      generator: PortableTextGenerator(
        output: "Das ist ein sachlicher Test mit 3,5 Millionen Euro."))
    let result = try await assistant.preview(
      TextTransformationRequest(
        selectedText: "Das ist äh ein sachlicher Test mit 3,5 Millionen Euro.",
        action: .polish))
    try expect(result.changed, "selection preview changed")
    try expect(result.transformedText.contains("3,5 Millionen Euro"), "selection facts preserved")
    do {
      _ = try OpenAICompatibleLocalTextGenerator(
        endpoint: URL(string: "http://example.com:18881")!, model: "remote")
      throw TestFailure.failed("selection assistant accepted remote host")
    } catch is TestFailure {
      throw TestFailure.failed("selection assistant accepted remote host")
    } catch {}
  }

  static func testVoiceAndMeetingFeatures() async throws {
    let parser = StructuredVoiceActionParser()
    let profile = try parser.parseTranscript("Wechsle zum Profil Research")
    try expect(profile.kind == .switchProfile && profile.profile == "research", "voice action")
    do {
      _ = try parser.parseModelJSON(
        Data(#"{"action":"run_shell","parameters":{"command":"rm"}}"#.utf8))
      throw TestFailure.failed("unsafe voice action accepted")
    } catch is TestFailure { throw TestFailure.failed("unsafe voice action accepted") } catch {}

    let transcript = AdaptiveTranscriptProcessor().process(
      "middle ei arbeitet lokal",
      entries: [SpeechLexiconEntry(spokenForm: "middle ei", writtenForm: "MiddleAI")],
      engineConfidence: 0.9, peakLevel: 0.12, duration: 2)
    try expect(transcript.corrected == "MiddleAI arbeitet lokal", "adaptive STT lexicon")
    try expect(
      abs(SpeechEngineBenchmark.wordErrorRate(reference: "a b c", hypothesis: "a c") - 1.0 / 3.0)
        < 0.0001, "STT word error rate")

    let coordinator = MeetingSessionCoordinator()
    _ = try await coordinator.start(title: "Projekt Alpha")
    try await coordinator.append(
      text: "Wir entscheiden, den Offline-Modus zuerst umzusetzen. Nächster Schritt ist der Test.",
      startTime: 0, endTime: 5)
    let meeting = try await coordinator.stop()
    try expect(meeting.summary.decisions.count == 1, "meeting decisions")
    try expect(meeting.summary.actionItems.count == 1, "meeting action items")
    try expect(
      MeetingExporter().markdown(for: meeting).contains("# Projekt Alpha"),
      "meeting markdown export")
  }

  private static func temporaryDirectory(_ suffix: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "middleai-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

private struct PortableTextGenerator: LocalTextGenerationProtocol {
  let output: String
  func complete(systemPrompt: String, userPrompt: String) async throws -> String { output }
}
