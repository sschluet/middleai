import Foundation
import XCTest

@testable import MiddleAICore

final class SecureVoiceActionTests: XCTestCase {
  func testStructuredParserRejectsUnknownActionsAndFields() throws {
    let parser = StructuredVoiceActionParser()
    XCTAssertThrowsError(
      try parser.parseModelJSON(Data(#"{"action":"run_shell","parameters":{"command":"rm"}}"#.utf8))
    ) { error in
      XCTAssertEqual(error as? VoiceActionParseError, .unsupportedAction("run_shell"))
    }
    XCTAssertThrowsError(
      try parser.parseModelJSON(
        Data(#"{"action":"new_conversation","parameters":{},"command":"rm"}"#.utf8))
    ) { error in
      XCTAssertEqual(error as? VoiceActionParseError, .unexpectedField("command"))
    }
    XCTAssertThrowsError(
      try parser.parseModelJSON(
        Data(#"{"action":"create_reminder","parameters":{"title":"Test","url":"file:///"}}"#.utf8))
    ) { error in
      XCTAssertEqual(error as? VoiceActionParseError, .unexpectedField("url"))
    }
  }

  func testStructuredParserProducesTypedRequests() throws {
    let parser = StructuredVoiceActionParser()
    let reminder = try parser.parseModelJSON(
      Data(
        #"{"action":"create_reminder","parameters":{"title":"Bericht prüfen","due_at":"2026-08-10T07:00:00Z"}}"#
          .utf8))
    XCTAssertEqual(reminder.kind, .createReminder)
    XCTAssertEqual(reminder.title, "Bericht prüfen")
    XCTAssertNotNil(reminder.dueAt)

    let profile = try parser.parseTranscript("Wechsle zum Profil Research")
    XCTAssertEqual(profile.kind, .switchProfile)
    XCTAssertEqual(profile.profile, "research")
  }

  func testConfirmationIsShortLivedBoundAndSingleUse() async {
    let gate = VoiceActionAuthorizationGate(confirmationLifetime: 10)
    let now = Date(timeIntervalSince1970: 1_000)
    let request = VoiceActionRequest(kind: .createReminder, title: "Test", createdAt: now)
    guard case .confirmationRequired(let token, _) = await gate.evaluate(request, now: now) else {
      return XCTFail("Expected confirmation")
    }
    let other = VoiceActionRequest(kind: .createReminder, title: "Other", createdAt: now)
    let mismatched = await gate.authorize(other, token: token, now: now.addingTimeInterval(1))
    XCTAssertFalse(mismatched)
    // A request mismatch consumes the token to prevent token probing and replay.
    let consumed = await gate.authorize(request, token: token, now: now.addingTimeInterval(1))
    XCTAssertFalse(consumed)

    guard case .confirmationRequired(let secondToken, _) = await gate.evaluate(request, now: now)
    else { return XCTFail("Expected confirmation") }
    let authorized = await gate.authorize(
      request, token: secondToken, now: now.addingTimeInterval(1))
    let replayed = await gate.authorize(
      request, token: secondToken, now: now.addingTimeInterval(2))
    XCTAssertTrue(authorized)
    XCTAssertFalse(replayed)
  }

  func testPolicyCanDisableActionsEntirely() async {
    let gate = VoiceActionAuthorizationGate(
      policy: VoiceActionPolicy(allowed: [.newConversation], requiresConfirmation: []))
    let reminder = VoiceActionRequest(kind: .createReminder, title: "Test")
    let conversation = VoiceActionRequest(kind: .newConversation)
    let rejected = await gate.evaluate(reminder)
    let approved = await gate.evaluate(conversation)
    XCTAssertEqual(rejected, .rejected)
    XCTAssertEqual(approved, .approved)
  }

  func testDispatcherNeverExecutesSideEffectBeforeConfirmation() async throws {
    let executor = RecordingVoiceActionExecutor()
    let dispatcher = SecureVoiceActionDispatcher(executor: executor)
    let now = Date(timeIntervalSince1970: 2_000)
    let request = VoiceActionRequest(kind: .createReminder, title: "Bericht", createdAt: now)
    let pending = try await dispatcher.dispatch(request, now: now)
    let beforeConfirmation = await executor.executedCount()
    XCTAssertEqual(beforeConfirmation, 0)
    guard case .confirmationRequired(_, let token, _) = pending else {
      return XCTFail("Expected confirmation")
    }
    let result = try await dispatcher.confirm(
      request: request, token: token, now: now.addingTimeInterval(1))
    XCTAssertEqual(result, .executed(VoiceActionExecutionResult(message: "executed")))
    let afterConfirmation = await executor.executedCount()
    XCTAssertEqual(afterConfirmation, 1)
  }
}

private actor RecordingVoiceActionExecutor: VoiceActionExecuting {
  private var requests: [VoiceActionRequest] = []
  func execute(_ request: VoiceActionRequest) async throws -> VoiceActionExecutionResult {
    requests.append(request)
    return VoiceActionExecutionResult(message: "executed")
  }
  func executedCount() -> Int { requests.count }
}

final class AdaptiveSpeechRecognitionTests: XCTestCase {
  func testNative16kMonoUSBInputFormatIsAccepted() {
    XCTAssertTrue(
      AudioCaptureFormatPolicy.isUsableHardwareInput(sampleRate: 16_000, channelCount: 1))
    XCTAssertFalse(
      AudioCaptureFormatPolicy.isUsableHardwareInput(sampleRate: 0, channelCount: 1))
    XCTAssertFalse(
      AudioCaptureFormatPolicy.isUsableHardwareInput(sampleRate: 48_000, channelCount: 0))
  }

  func testLexiconIsScopedAndRequiresExplicitApproval() async throws {
    let store = try SpeechLexiconStore()
    _ = try await store.recordCorrection(
      spokenForm: "middle ei", writtenForm: "MiddleAI", userApproved: true)
    _ = try await store.recordCorrection(
      spokenForm: "awendis", writtenForm: "AVENDIS",
      scope: SpeechLexiconScope(profileID: "work", applicationBundleID: "com.microsoft.Word"),
      userApproved: true)
    await assertThrowsErrorAsync {
      _ = try await store.recordCorrection(
        spokenForm: "heimlich", writtenForm: "gelernt", userApproved: false)
    }

    let workEntries = await store.entries(
      profileID: "work", applicationBundleID: "com.microsoft.Word")
    let personalEntries = await store.entries(
      profileID: "private", applicationBundleID: "com.apple.TextEdit")
    XCTAssertEqual(Set(workEntries.map(\.writtenForm)), ["MiddleAI", "AVENDIS"])
    XCTAssertEqual(personalEntries.map(\.writtenForm), ["MiddleAI"])
  }

  func testAdaptivePostprocessorAppliesLongestScopedPhrasesAndReportsQuality() {
    let entries = [
      SpeechLexiconEntry(spokenForm: "middle ei", writtenForm: "MiddleAI"),
      SpeechLexiconEntry(spokenForm: "avendis gmbh", writtenForm: "AVENDIS GmbH"),
    ]
    let result = AdaptiveTranscriptProcessor().process(
      "middle ei arbeitet für Avendis GmbH", entries: entries, engineConfidence: 0.9,
      peakLevel: 0.12, duration: 3)
    XCTAssertEqual(result.corrected, "MiddleAI arbeitet für AVENDIS GmbH")
    XCTAssertEqual(result.appliedEntryIDs.count, 2)
    XCTAssertGreaterThan(result.quality.confidence, 0.75)
    XCTAssertEqual(result.quality.lexiconMatches, 2)
  }

  func testApprovedLexiconPersistsLocally() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "middleai-lexicon-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("speech-lexicon.json")
    let first = try SpeechLexiconStore(fileURL: url)
    _ = try await first.recordCorrection(
      spokenForm: "schlüter busch", writtenForm: "Schlüterbusch", userApproved: true)

    let reloaded = try SpeechLexiconStore(fileURL: url)
    let entries = await reloaded.entries(profileID: nil, applicationBundleID: nil)
    XCTAssertEqual(entries.map(\.writtenForm), ["Schlüterbusch"])
    let permissions =
      try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
      as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
  }

  func testWordErrorRateAndEngineComparison() async {
    let sample = SpeechRecognitionSample(
      samples: [0, 0], sampleRate: 16_000, duration: 1,
      referenceTranscript: "MiddleAI versteht Sprache")
    let engines: [any SpeechRecognitionEngine] = [
      StubSpeechEngine(id: "wrong", text: "MiddleAI Sprache"),
      StubSpeechEngine(id: "exact", text: "MiddleAI versteht Sprache"),
    ]
    let results = await SpeechEngineBenchmark().compare(engines: engines, sample: sample)
    XCTAssertEqual(results.first?.engineID, "exact")
    XCTAssertEqual(results.first?.wordErrorRate, 0)
    XCTAssertEqual(
      SpeechEngineBenchmark.wordErrorRate(
        reference: "MiddleAI versteht Sprache", hypothesis: "MiddleAI Sprache"),
      1.0 / 3.0, accuracy: 0.0001)
  }
}

private struct StubSpeechEngine: SpeechRecognitionEngine {
  let id: String
  let text: String
  var identifier: String { id }
  var displayName: String { id }
  func transcribe(_ sample: SpeechRecognitionSample) async throws -> SpeechRecognitionResult {
    SpeechRecognitionResult(text: text, confidence: 0.8)
  }
}

final class MeetingSessionTests: XCTestCase {
  func testExplicitMeetingLifecycleSummaryAndExport() async throws {
    let coordinator = MeetingSessionCoordinator()
    let start = Date(timeIntervalSince1970: 1_000)
    let started = try await coordinator.start(title: "Projekt Alpha", at: start)
    XCTAssertEqual(started.captureCapabilities, [.microphone])
    try await coordinator.append(
      text: "Das wichtigste Ziel ist ein lokaler Assistent.", startTime: 0, endTime: 4,
      speaker: "Sebastian", confidence: 0.92)
    try await coordinator.append(
      text: "Wir entscheiden, den Offline-Modus zuerst umzusetzen. Nächster Schritt ist der Test.",
      startTime: 4, endTime: 10, speaker: "Team")

    let session = try await coordinator.stop(
      at: start.addingTimeInterval(10))
    XCTAssertTrue(session.summary.overview.contains("wichtigste Ziel"))
    XCTAssertEqual(session.summary.decisions.count, 1)
    XCTAssertEqual(session.summary.actionItems.count, 1)
    let finalState = await coordinator.state
    XCTAssertEqual(finalState, .idle)

    let markdown = MeetingExporter().markdown(for: session)
    XCTAssertTrue(markdown.contains("# Projekt Alpha"))
    XCTAssertTrue(markdown.contains("[00:00:04] **Team:**"))
    XCTAssertTrue(markdown.contains("- [ ]"))
  }

  func testMeetingRejectsImplicitOrEmptyFinalizationAndCanCancel() async throws {
    let coordinator = MeetingSessionCoordinator()
    await assertThrowsErrorAsync {
      try await coordinator.append(text: "Ohne Start", startTime: 0, endTime: 1)
    }
    _ = try await coordinator.start()
    await assertThrowsErrorAsync { _ = try await coordinator.stop() }
    await coordinator.cancel()
    let cancelledState = await coordinator.state
    XCTAssertEqual(cancelledState, .idle)
  }

  func testSystemAudioIsCapabilityNotAnImplicitPermissionRequest() async throws {
    let coordinator = MeetingSessionCoordinator()
    let session = try await coordinator.start(
      capabilities: [.microphone, .systemAudio])
    XCTAssertEqual(session.captureCapabilities, [.microphone, .systemAudio])
    await coordinator.cancel()
  }

  func testCapturePipelineUsesExplicitAudioSourceAdapter() async throws {
    let pipeline = MeetingCapturePipeline()
    let source = StubMeetingAudioSource()
    _ = try await pipeline.start(
      title: "Adapter Test", source: source, transcriber: StubMeetingTranscriber())
    let session = try await pipeline.stop()
    XCTAssertEqual(session.segments.map(\.text), ["Lokale Transkription"])
    XCTAssertEqual(session.captureCapabilities, [.microphone])
  }

  func testMeetingFallsBackToLocalExtractiveSummary() async throws {
    let coordinator = MeetingSessionCoordinator()
    _ = try await coordinator.start()
    try await coordinator.append(
      text: "Das wichtigste Ergebnis ist ein stabiler lokaler Betrieb.", startTime: 0,
      endTime: 2)
    let session = try await coordinator.stop(summarizer: FailingMeetingSummarizer())
    XCTAssertTrue(session.summary.overview.contains("wichtigste Ergebnis"))
  }
}

private final class StubMeetingAudioSource: MeetingAudioSource, @unchecked Sendable {
  let identifier = "microphone-test"
  let capabilities: Set<MeetingCaptureCapability> = [.microphone]
  private let stream: AsyncThrowingStream<MeetingAudioFrame, Error>

  init() {
    stream = AsyncThrowingStream { continuation in
      continuation.yield(
        MeetingAudioFrame(samples: [0.1, 0.2], sampleRate: 16_000, timestamp: 0))
      continuation.finish()
    }
  }

  func audioFrames() async throws -> AsyncThrowingStream<MeetingAudioFrame, Error> { stream }
  func stop() async {}
}

private struct StubMeetingTranscriber: MeetingAudioTranscribing {
  func transcribe(_ frame: MeetingAudioFrame) async throws -> MeetingFrameTranscription? {
    MeetingFrameTranscription(text: "Lokale Transkription", startTime: 0, endTime: 1)
  }
}

private struct FailingMeetingSummarizer: MeetingSummarizing {
  struct Failure: Error {}
  func summarize(segments: [MeetingTranscriptSegment]) async throws -> MeetingSummary {
    throw Failure()
  }
}

private func assertThrowsErrorAsync<T: Sendable>(
  _ expression: () async throws -> T,
  file: StaticString = #filePath, line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected error", file: file, line: line)
  } catch {}
}
