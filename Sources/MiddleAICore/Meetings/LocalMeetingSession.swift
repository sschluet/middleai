import Foundation

public enum MeetingCaptureCapability: String, Codable, CaseIterable, Sendable {
  case microphone
  case systemAudio = "system_audio"
}

/// Audio-source abstraction for the existing microphone pipeline and a future ScreenCaptureKit
/// adapter. Core does not request screen-recording permission by itself.
public protocol MeetingAudioSource: Sendable {
  var identifier: String { get }
  var capabilities: Set<MeetingCaptureCapability> { get }
  func audioFrames() async throws -> AsyncThrowingStream<MeetingAudioFrame, Error>
  func stop() async
}

public struct MeetingAudioFrame: Sendable {
  public var samples: [Float]
  public var sampleRate: Double
  public var timestamp: TimeInterval

  public init(samples: [Float], sampleRate: Double, timestamp: TimeInterval) {
    self.samples = samples
    self.sampleRate = sampleRate
    self.timestamp = timestamp
  }
}

public struct MeetingFrameTranscription: Equatable, Sendable {
  public var text: String
  public var startTime: TimeInterval
  public var endTime: TimeInterval
  public var speaker: String?
  public var confidence: Double?

  public init(
    text: String, startTime: TimeInterval, endTime: TimeInterval, speaker: String? = nil,
    confidence: Double? = nil
  ) {
    self.text = text
    self.startTime = startTime
    self.endTime = endTime
    self.speaker = speaker
    self.confidence = confidence
  }
}

public protocol MeetingAudioTranscribing: Sendable {
  func transcribe(_ frame: MeetingAudioFrame) async throws -> MeetingFrameTranscription?
}

public struct MeetingTranscriptSegment: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var startTime: TimeInterval
  public var endTime: TimeInterval
  public var speaker: String?
  public var text: String
  public var confidence: Double?

  public init(
    id: UUID = UUID(), startTime: TimeInterval, endTime: TimeInterval, speaker: String? = nil,
    text: String, confidence: Double? = nil
  ) {
    self.id = id
    self.startTime = startTime
    self.endTime = endTime
    self.speaker = speaker
    self.text = text
    self.confidence = confidence
  }
}

public struct MeetingSummary: Codable, Equatable, Sendable {
  public var overview: String
  public var decisions: [String]
  public var actionItems: [String]

  public init(overview: String = "", decisions: [String] = [], actionItems: [String] = []) {
    self.overview = overview
    self.decisions = decisions
    self.actionItems = actionItems
  }
}

public struct MeetingSession: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var title: String
  public var startedAt: Date
  public var endedAt: Date?
  public var captureCapabilities: Set<MeetingCaptureCapability>
  public var segments: [MeetingTranscriptSegment]
  public var summary: MeetingSummary

  public init(
    id: UUID = UUID(), title: String, startedAt: Date = Date(), endedAt: Date? = nil,
    captureCapabilities: Set<MeetingCaptureCapability> = [.microphone],
    segments: [MeetingTranscriptSegment] = [], summary: MeetingSummary = MeetingSummary()
  ) {
    self.id = id
    self.title = title
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.captureCapabilities = captureCapabilities
    self.segments = segments
    self.summary = summary
  }

  public var transcript: String {
    segments.map(\.text).joined(separator: "\n")
  }
}

public protocol MeetingSummarizing: Sendable {
  func summarize(segments: [MeetingTranscriptSegment]) async throws -> MeetingSummary
}

/// Fully local and deterministic fallback. A local LLM can implement `MeetingSummarizing`
/// without changing session or export code.
public struct ExtractiveMeetingSummarizer: MeetingSummarizing {
  public var maximumOverviewSentences: Int

  public init(maximumOverviewSentences: Int = 5) {
    self.maximumOverviewSentences = max(1, maximumOverviewSentences)
  }

  public func summarize(segments: [MeetingTranscriptSegment]) async throws -> MeetingSummary {
    let sentences = Self.sentences(from: segments)
    let decisions = sentences.filter { sentence in
      Self.containsAny(
        sentence,
        terms: [
          "wir entscheiden", "beschlossen", "entscheidung", "wir einigen uns", "festgelegt",
          "agreed", "decision",
        ])
    }
    let actionItems = sentences.filter { sentence in
      Self.containsAny(
        sentence,
        terms: [
          "aufgabe", "nächster schritt", "muss ", "soll ", "kümmert sich", "bis zum", "todo",
          "action item", "next step",
        ])
    }
    let priority = sentences.filter { sentence in
      Self.containsAny(
        sentence,
        terms: [
          "wichtig", "ergebnis", "risiko", "ziel", "fazit", "problem", "entscheid",
        ])
    }
    var overview: [String] = []
    for sentence in priority + sentences where !overview.contains(sentence) {
      overview.append(sentence)
      if overview.count >= maximumOverviewSentences { break }
    }
    return MeetingSummary(
      overview: overview.joined(separator: " "),
      decisions: Array(decisions.prefix(12)), actionItems: Array(actionItems.prefix(20)))
  }

  private static func sentences(from segments: [MeetingTranscriptSegment]) -> [String] {
    segments.flatMap { segment in
      segment.text.split(whereSeparator: { ".!?\n".contains($0) }).map {
        let text = $0.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "" : text + "."
      }
    }.filter { !$0.isEmpty }
  }

  private static func containsAny(_ text: String, terms: [String]) -> Bool {
    let normalized = text.folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
    return terms.contains {
      normalized.contains(
        $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
    }
  }
}

public enum MeetingSessionError: LocalizedError, Equatable {
  case alreadyRecording
  case notRecording
  case invalidSegment
  case emptyMeeting

  public var errorDescription: String? {
    switch self {
    case .alreadyRecording: return "Eine Besprechungsaufnahme läuft bereits."
    case .notRecording: return "Es läuft keine Besprechungsaufnahme."
    case .invalidSegment: return "Das Transkriptsegment ist leer oder hat ungültige Zeitmarken."
    case .emptyMeeting: return "Die Besprechung enthält noch kein Transkript."
    }
  }
}

public enum MeetingSessionState: Equatable, Sendable {
  case idle
  case recording(MeetingSession)
  case finalizing(UUID)
}

/// Explicit lifecycle controller. Nothing starts in the background and cancel discards the draft.
public actor MeetingSessionCoordinator {
  private var current: MeetingSession?
  private var finalizingID: UUID?

  public init() {}

  public var state: MeetingSessionState {
    if let current { return .recording(current) }
    if let finalizingID { return .finalizing(finalizingID) }
    return .idle
  }

  @discardableResult
  public func start(
    title: String? = nil, capabilities: Set<MeetingCaptureCapability> = [.microphone],
    at date: Date = Date()
  ) throws -> MeetingSession {
    guard current == nil, finalizingID == nil else { throw MeetingSessionError.alreadyRecording }
    let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    let session = MeetingSession(
      title: resolvedTitle?.isEmpty == false ? resolvedTitle! : "Besprechung", startedAt: date,
      captureCapabilities: capabilities.isEmpty ? [.microphone] : capabilities)
    current = session
    return session
  }

  public func append(
    text: String, startTime: TimeInterval, endTime: TimeInterval, speaker: String? = nil,
    confidence: Double? = nil
  ) throws {
    guard var session = current else { throw MeetingSessionError.notRecording }
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, startTime >= 0, endTime >= startTime else {
      throw MeetingSessionError.invalidSegment
    }
    let minimumStart = session.segments.last?.endTime ?? 0
    let segment = MeetingTranscriptSegment(
      startTime: max(startTime, minimumStart), endTime: max(endTime, minimumStart),
      speaker: speaker?.trimmingCharacters(in: .whitespacesAndNewlines), text: normalized,
      confidence: confidence.map { min(1, max(0, $0)) })
    session.segments.append(segment)
    current = session
  }

  public func snapshot() -> MeetingSession? { current }

  public func stop(
    summarizer: any MeetingSummarizing = ExtractiveMeetingSummarizer(), at date: Date = Date()
  ) async throws -> MeetingSession {
    guard var session = current else { throw MeetingSessionError.notRecording }
    guard !session.segments.isEmpty else { throw MeetingSessionError.emptyMeeting }
    current = nil
    finalizingID = session.id
    do {
      session.endedAt = max(date, session.startedAt)
      session.summary = try await summarizer.summarize(segments: session.segments)
      finalizingID = nil
      return session
    } catch {
      do {
        session.summary = try await ExtractiveMeetingSummarizer().summarize(
          segments: session.segments)
        finalizingID = nil
        return session
      } catch {
        finalizingID = nil
        session.endedAt = nil
        current = session
        throw error
      }
    }
  }

  public func cancel() {
    current = nil
    finalizingID = nil
  }
}

/// Connects a concrete microphone or ScreenCaptureKit source to a transcription engine. It owns
/// no global capture state and only starts after an explicit call to `start`.
public actor MeetingCapturePipeline {
  private let coordinator: MeetingSessionCoordinator
  private var source: (any MeetingAudioSource)?
  private var captureTask: Task<Void, Error>?
  private var captureError: Error?

  public init(coordinator: MeetingSessionCoordinator = MeetingSessionCoordinator()) {
    self.coordinator = coordinator
  }

  @discardableResult
  public func start(
    title: String? = nil, source: any MeetingAudioSource,
    transcriber: any MeetingAudioTranscribing, at date: Date = Date()
  ) async throws -> MeetingSession {
    guard captureTask == nil else { throw MeetingSessionError.alreadyRecording }
    let session = try await coordinator.start(
      title: title, capabilities: source.capabilities, at: date)
    do {
      let stream = try await source.audioFrames()
      self.source = source
      captureError = nil
      captureTask = Task { [coordinator] in
        for try await frame in stream {
          try Task.checkCancellation()
          let result = try await InferenceScheduler.shared.run(
            workload: .speechRecognition, priority: .realtime
          ) {
            try await transcriber.transcribe(frame)
          }
          guard let result else { continue }
          try await coordinator.append(
            text: result.text, startTime: result.startTime, endTime: result.endTime,
            speaker: result.speaker, confidence: result.confidence)
        }
      }
      return session
    } catch {
      await coordinator.cancel()
      throw error
    }
  }

  public func stop(
    summarizer: any MeetingSummarizing = ExtractiveMeetingSummarizer(), at date: Date = Date()
  ) async throws -> MeetingSession {
    guard let captureTask, let source else { throw MeetingSessionError.notRecording }
    await source.stop()
    do {
      try await captureTask.value
    } catch is CancellationError {
      // User-initiated stop is a normal end to an asynchronous audio stream.
    } catch {
      captureError = error
    }
    self.captureTask = nil
    self.source = nil
    if let captureError {
      self.captureError = nil
      await coordinator.cancel()
      throw captureError
    }
    return try await coordinator.stop(summarizer: summarizer, at: date)
  }

  public func cancel() async {
    captureTask?.cancel()
    if let source { await source.stop() }
    captureTask = nil
    source = nil
    captureError = nil
    await coordinator.cancel()
  }

  public func snapshot() async -> MeetingSession? { await coordinator.snapshot() }
}

public enum MeetingExportFormat: String, Sendable { case markdown, json }

public struct MeetingExporter: Sendable {
  public init() {}

  public func data(for session: MeetingSession, format: MeetingExportFormat) throws -> Data {
    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      return try encoder.encode(session)
    case .markdown:
      return Data(markdown(for: session).utf8)
    }
  }

  @discardableResult
  public func export(
    _ session: MeetingSession, format: MeetingExportFormat, to directory: URL
  ) throws -> URL {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    let baseName = Self.safeFilename(session.title) + "-" + String(session.id.uuidString.prefix(8))
    let path = directory.appendingPathComponent(
      baseName + (format == .markdown ? ".md" : ".json"))
    try data(for: session, format: format).write(to: path, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: path.path)
    return path
  }

  public func markdown(for session: MeetingSession) -> String {
    var lines = ["# \(session.title)", "", "Beginn: \(Self.iso8601(session.startedAt))"]
    if let endedAt = session.endedAt { lines.append("Ende: \(Self.iso8601(endedAt))") }
    lines += ["", "## Zusammenfassung", "", session.summary.overview]
    if !session.summary.decisions.isEmpty {
      lines += ["", "## Entscheidungen", ""]
      lines += session.summary.decisions.map { "- \($0)" }
    }
    if !session.summary.actionItems.isEmpty {
      lines += ["", "## Aufgaben", ""]
      lines += session.summary.actionItems.map { "- [ ] \($0)" }
    }
    lines += ["", "## Transkript", ""]
    for segment in session.segments {
      let speaker = segment.speaker.map { " **\($0):**" } ?? ""
      lines.append("[\(Self.timestamp(segment.startTime))]\(speaker) \(segment.text)")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func timestamp(_ seconds: TimeInterval) -> String {
    let value = max(0, Int(seconds.rounded(.down)))
    return String(format: "%02d:%02d:%02d", value / 3_600, value / 60 % 60, value % 60)
  }

  private static func iso8601(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

  private static func safeFilename(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let normalized = value.folding(options: .diacriticInsensitive, locale: .current)
    let mapped = normalized.unicodeScalars.map {
      allowed.contains($0) ? Character(String($0)) : "-"
    }
    let collapsed = String(mapped).replacingOccurrences(
      of: "-+", with: "-", options: .regularExpression
    ).trimmingCharacters(
      in: CharacterSet(charactersIn: "-"))
    return collapsed.isEmpty ? "meeting" : String(collapsed.prefix(80))
  }
}

public actor MeetingArchiveStore {
  private let directory: URL

  public init(directory: URL) { self.directory = directory }

  @discardableResult
  public func save(_ session: MeetingSession) throws -> URL {
    try MeetingExporter().export(session, format: .json, to: directory)
  }

  public func sessions() throws -> [MeetingSession] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "json" }.compactMap { url in
      try? decoder.decode(MeetingSession.self, from: Data(contentsOf: url))
    }.sorted { $0.startedAt > $1.startedAt }
  }
}
