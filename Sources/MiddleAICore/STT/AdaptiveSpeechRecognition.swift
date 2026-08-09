import Foundation

public struct SpeechLexiconScope: Codable, Hashable, Sendable {
  public var profileID: String?
  public var applicationBundleID: String?

  public init(profileID: String? = nil, applicationBundleID: String? = nil) {
    self.profileID = profileID
    self.applicationBundleID = applicationBundleID
  }

  public static let global = SpeechLexiconScope()
}

public struct SpeechLexiconEntry: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var spokenForm: String
  public var writtenForm: String
  public var scope: SpeechLexiconScope
  public var userApproved: Bool
  public var updatedAt: Date

  public init(
    id: UUID = UUID(), spokenForm: String, writtenForm: String,
    scope: SpeechLexiconScope = .global, userApproved: Bool = true, updatedAt: Date = Date()
  ) {
    self.id = id
    self.spokenForm = spokenForm
    self.writtenForm = writtenForm
    self.scope = scope
    self.userApproved = userApproved
    self.updatedAt = updatedAt
  }
}

public enum SpeechLexiconError: LocalizedError, Equatable {
  case invalidEntry
  case persistence(String)

  public var errorDescription: String? {
    switch self {
    case .invalidEntry: return "Der Wörterbucheintrag ist leer oder zu lang."
    case .persistence(let detail):
      return "Das lokale Sprachwörterbuch konnte nicht gespeichert werden: \(detail)"
    }
  }
}

/// A small, user-controlled JSON store. Corrections are never learned implicitly: callers must
/// pass `userApproved: true`, which makes the privacy boundary explicit at the API.
public actor SpeechLexiconStore {
  private struct Document: Codable { var entries: [SpeechLexiconEntry] }

  private let fileURL: URL?
  private var entriesByID: [UUID: SpeechLexiconEntry]

  public init(fileURL: URL? = nil) throws {
    self.fileURL = fileURL
    if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
      do {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(Document.self, from: data)
        entriesByID = Dictionary(uniqueKeysWithValues: document.entries.map { ($0.id, $0) })
      } catch {
        throw SpeechLexiconError.persistence(error.localizedDescription)
      }
    } else {
      entriesByID = [:]
    }
  }

  public func allEntries() -> [SpeechLexiconEntry] {
    entriesByID.values.sorted { $0.updatedAt > $1.updatedAt }
  }

  public func entries(profileID: String?, applicationBundleID: String?) -> [SpeechLexiconEntry] {
    entriesByID.values.filter { entry in
      let scope = entry.scope
      let profileMatches = scope.profileID == nil || scope.profileID == profileID
      let applicationMatches =
        scope.applicationBundleID == nil || scope.applicationBundleID == applicationBundleID
      return profileMatches && applicationMatches && entry.userApproved
    }.sorted {
      let lhsSpecificity =
        ($0.scope.profileID == nil ? 0 : 1) + ($0.scope.applicationBundleID == nil ? 0 : 1)
      let rhsSpecificity =
        ($1.scope.profileID == nil ? 0 : 1) + ($1.scope.applicationBundleID == nil ? 0 : 1)
      if lhsSpecificity != rhsSpecificity { return lhsSpecificity > rhsSpecificity }
      return $0.spokenForm.count > $1.spokenForm.count
    }
  }

  @discardableResult
  public func recordCorrection(
    spokenForm: String, writtenForm: String, scope: SpeechLexiconScope = .global,
    userApproved: Bool
  ) throws -> SpeechLexiconEntry {
    let spoken = spokenForm.trimmingCharacters(in: .whitespacesAndNewlines)
    let written = writtenForm.trimmingCharacters(in: .whitespacesAndNewlines)
    guard userApproved, !spoken.isEmpty, !written.isEmpty, spoken.count <= 200, written.count <= 200
    else { throw SpeechLexiconError.invalidEntry }

    let existing = entriesByID.values.first {
      $0.scope == scope && $0.spokenForm.compare(spoken, options: .caseInsensitive) == .orderedSame
    }
    let entry = SpeechLexiconEntry(
      id: existing?.id ?? UUID(), spokenForm: spoken, writtenForm: written, scope: scope,
      userApproved: true)
    entriesByID[entry.id] = entry
    try persist()
    return entry
  }

  public func remove(id: UUID) throws {
    entriesByID.removeValue(forKey: id)
    try persist()
  }

  public func removeAll(scope: SpeechLexiconScope? = nil) throws {
    if let scope {
      entriesByID = entriesByID.filter { $0.value.scope != scope }
    } else {
      entriesByID.removeAll()
    }
    try persist()
  }

  private func persist() throws {
    guard let fileURL else { return }
    do {
      let directory = fileURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(Document(entries: allEntries()))
      try data.write(to: fileURL, options: [.atomic])
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: fileURL.path)
    } catch {
      throw SpeechLexiconError.persistence(error.localizedDescription)
    }
  }
}

public struct AdaptiveTranscript: Equatable, Sendable {
  public var original: String
  public var corrected: String
  public var appliedEntryIDs: [UUID]
  public var quality: TranscriptQualityMetrics

  public init(
    original: String, corrected: String, appliedEntryIDs: [UUID],
    quality: TranscriptQualityMetrics
  ) {
    self.original = original
    self.corrected = corrected
    self.appliedEntryIDs = appliedEntryIDs
    self.quality = quality
  }
}

public struct TranscriptQualityMetrics: Equatable, Sendable {
  public var confidence: Double
  public var wordCount: Int
  public var lexiconMatches: Int
  public var signalQuality: Double
  public var warnings: [String]

  public init(
    confidence: Double, wordCount: Int, lexiconMatches: Int, signalQuality: Double,
    warnings: [String]
  ) {
    self.confidence = confidence
    self.wordCount = wordCount
    self.lexiconMatches = lexiconMatches
    self.signalQuality = signalQuality
    self.warnings = warnings
  }
}

public struct AdaptiveTranscriptProcessor: Sendable {
  public init() {}

  public func process(
    _ transcript: String, entries: [SpeechLexiconEntry], engineConfidence: Double? = nil,
    peakLevel: Float? = nil, duration: TimeInterval? = nil
  ) -> AdaptiveTranscript {
    var result = transcript
    var applied: [UUID] = []
    for entry in entries.sorted(by: {
      if $0.spokenForm.count != $1.spokenForm.count {
        return $0.spokenForm.count > $1.spokenForm.count
      }
      let lhsSpecificity =
        ($0.scope.profileID == nil ? 0 : 1) + ($0.scope.applicationBundleID == nil ? 0 : 1)
      let rhsSpecificity =
        ($1.scope.profileID == nil ? 0 : 1) + ($1.scope.applicationBundleID == nil ? 0 : 1)
      return lhsSpecificity > rhsSpecificity
    }) {
      let pattern =
        "(?<![\\p{L}\\p{N}])\(NSRegularExpression.escapedPattern(for: entry.spokenForm))(?![\\p{L}\\p{N}])"
      guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
      else { continue }
      let range = NSRange(result.startIndex..<result.endIndex, in: result)
      guard expression.firstMatch(in: result, range: range) != nil else { continue }
      result = expression.stringByReplacingMatches(
        in: result, range: range,
        withTemplate: NSRegularExpression.escapedTemplate(for: entry.writtenForm))
      applied.append(entry.id)
    }
    let quality = TranscriptQualityEvaluator().evaluate(
      result, engineConfidence: engineConfidence, peakLevel: peakLevel, duration: duration,
      lexiconMatches: applied.count)
    return AdaptiveTranscript(
      original: transcript, corrected: result, appliedEntryIDs: applied, quality: quality)
  }
}

/// Ready-to-integrate actor used by a voice controller after the current STT engine returns. An
/// empty lexicon is a no-op, so enabling it cannot change Parakeet decoding behavior.
public actor AdaptiveSpeechService {
  public static var defaultStoreURL: URL {
    ConfigLoader.defaultDirectory.appendingPathComponent("speech-lexicon.json")
  }

  private let store: SpeechLexiconStore
  private let processor = AdaptiveTranscriptProcessor()

  public init(store: SpeechLexiconStore) { self.store = store }

  public static func live() throws -> AdaptiveSpeechService {
    try AdaptiveSpeechService(store: SpeechLexiconStore(fileURL: defaultStoreURL))
  }

  public func process(
    _ transcript: String, profileID: String?, applicationBundleID: String?,
    engineConfidence: Double? = nil, peakLevel: Float? = nil, duration: TimeInterval? = nil
  ) async -> AdaptiveTranscript {
    let entries = await store.entries(
      profileID: profileID, applicationBundleID: applicationBundleID)
    return processor.process(
      transcript, entries: entries, engineConfidence: engineConfidence, peakLevel: peakLevel,
      duration: duration)
  }

  @discardableResult
  public func approveCorrection(
    spokenForm: String, writtenForm: String, profileID: String? = nil,
    applicationBundleID: String? = nil
  ) async throws -> SpeechLexiconEntry {
    try await store.recordCorrection(
      spokenForm: spokenForm, writtenForm: writtenForm,
      scope: SpeechLexiconScope(
        profileID: profileID, applicationBundleID: applicationBundleID),
      userApproved: true)
  }
}

public struct TranscriptQualityEvaluator: Sendable {
  public init() {}

  public func evaluate(
    _ transcript: String, engineConfidence: Double? = nil, peakLevel: Float? = nil,
    duration: TimeInterval? = nil, lexiconMatches: Int = 0
  ) -> TranscriptQualityMetrics {
    let words = transcript.split { !$0.isLetter && !$0.isNumber }
    let signal = min(1, max(0, Double(peakLevel ?? 0.5) / 0.16))
    let lexical = words.isEmpty ? 0 : min(1, Double(words.count) / 6.0)
    let engine = min(1, max(0, engineConfidence ?? (0.55 + lexical * 0.25)))
    let confidence = min(1, max(0, engine * 0.65 + signal * 0.25 + lexical * 0.10))
    var warnings: [String] = []
    if signal < 0.25 { warnings.append("low_signal") }
    if words.count < 2 { warnings.append("very_short_transcript") }
    if let duration, duration > 8, words.count < 3 { warnings.append("speech_density_low") }
    if confidence < 0.5 { warnings.append("low_confidence") }
    return TranscriptQualityMetrics(
      confidence: confidence, wordCount: words.count, lexiconMatches: lexiconMatches,
      signalQuality: signal, warnings: warnings)
  }
}

public struct SpeechRecognitionSample: Sendable {
  public var samples: [Float]
  public var sampleRate: Double
  public var duration: TimeInterval
  public var referenceTranscript: String?

  public init(
    samples: [Float], sampleRate: Double, duration: TimeInterval,
    referenceTranscript: String? = nil
  ) {
    self.samples = samples
    self.sampleRate = sampleRate
    self.duration = duration
    self.referenceTranscript = referenceTranscript
  }
}

public struct SpeechRecognitionResult: Equatable, Sendable {
  public var text: String
  public var confidence: Double?

  public init(text: String, confidence: Double? = nil) {
    self.text = text
    self.confidence = confidence
  }
}

public protocol SpeechRecognitionEngine: Sendable {
  var identifier: String { get }
  var displayName: String { get }
  func transcribe(_ sample: SpeechRecognitionSample) async throws -> SpeechRecognitionResult
}

public struct SpeechEngineBenchmarkResult: Equatable, Sendable {
  public var engineID: String
  public var displayName: String
  public var latency: TimeInterval
  public var realTimeFactor: Double
  public var wordErrorRate: Double?
  public var confidence: Double?
  public var transcript: String
}

public struct SpeechEngineBenchmark: Sendable {
  public init() {}

  public func compare(
    engines: [any SpeechRecognitionEngine], sample: SpeechRecognitionSample
  ) async -> [SpeechEngineBenchmarkResult] {
    var results: [SpeechEngineBenchmarkResult] = []
    for engine in engines {
      let started = ContinuousClock.now
      guard let recognition = try? await engine.transcribe(sample) else { continue }
      let elapsed = started.duration(to: .now).components
      let latency = Double(elapsed.attoseconds) / 1e18 + Double(elapsed.seconds)
      let errorRate = sample.referenceTranscript.map {
        Self.wordErrorRate(reference: $0, hypothesis: recognition.text)
      }
      results.append(
        SpeechEngineBenchmarkResult(
          engineID: engine.identifier, displayName: engine.displayName, latency: latency,
          realTimeFactor: sample.duration > 0 ? latency / sample.duration : 0,
          wordErrorRate: errorRate, confidence: recognition.confidence,
          transcript: recognition.text))
    }
    return results.sorted {
      switch ($0.wordErrorRate, $1.wordErrorRate) {
      case (let lhs?, let rhs?) where lhs != rhs: return lhs < rhs
      default: return $0.realTimeFactor < $1.realTimeFactor
      }
    }
  }

  public static func wordErrorRate(reference: String, hypothesis: String) -> Double {
    let referenceWords = normalizedWords(reference)
    let hypothesisWords = normalizedWords(hypothesis)
    guard !referenceWords.isEmpty else { return hypothesisWords.isEmpty ? 0 : 1 }
    var previous = Array(0...hypothesisWords.count)
    for (row, referenceWord) in referenceWords.enumerated() {
      var current = [row + 1] + Array(repeating: 0, count: hypothesisWords.count)
      for (column, hypothesisWord) in hypothesisWords.enumerated() {
        current[column + 1] = min(
          previous[column + 1] + 1, current[column] + 1,
          previous[column] + (referenceWord == hypothesisWord ? 0 : 1))
      }
      previous = current
    }
    return Double(previous[hypothesisWords.count]) / Double(referenceWords.count)
  }

  private static func normalizedWords(_ text: String) -> [String] {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .split { !$0.isLetter && !$0.isNumber }.map(String.init)
  }
}
