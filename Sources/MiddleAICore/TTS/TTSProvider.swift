@preconcurrency import AVFoundation
import CryptoKit
import FluidAudio
import Foundation
@preconcurrency import MLXAudioTTS
import NaturalLanguage

@MainActor public protocol TTSProvider: AnyObject {
  var isSpeaking: Bool { get }
  func prepare() async throws
  func speak(_ text: String) async throws
  func stop()
}

extension TTSProvider {
  public func prepare() async throws {}
}

/// Shared application-level output preference. `system_default` deliberately leaves routing to
/// macOS; a concrete Core Audio UID is applied only to MiddleAI's AVAudioPlayer instance.
@MainActor public enum TTSOutputDevicePreference {
  public static var uid = "system_default"
}

@MainActor private final class AudioFilePlayer: NSObject {
  private var player: AVAudioPlayer?
  private var continuation: CheckedContinuation<Void, Error>?
  var isPlaying: Bool { player?.isPlaying == true }

  func play(_ url: URL) async throws {
    stop()
    let next = try AVAudioPlayer(contentsOf: url)
    if TTSOutputDevicePreference.uid != "system_default" {
      next.currentDevice = TTSOutputDevicePreference.uid
    }
    next.delegate = self
    next.prepareToPlay()
    player = next
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      if !next.play(), TTSOutputDevicePreference.uid != "system_default" {
        next.currentDevice = nil
        next.prepareToPlay()
      }
      guard next.isPlaying || next.play() else {
        self.continuation = nil
        self.player = nil
        continuation.resume(
          throwing: MiddleAIError.invalidResponse("Es ist kein Ausgabegerät verfügbar"))
        return
      }
    }
  }

  func stop() {
    player?.stop()
    player = nil
    continuation?.resume()
    continuation = nil
  }

  fileprivate func didFinish(successfully flag: Bool) {
    self.player = nil
    let pending = continuation
    continuation = nil
    if flag {
      pending?.resume()
    } else {
      pending?.resume(
        throwing: MiddleAIError.invalidResponse("Die Audiowiedergabe wurde unterbrochen"))
    }
  }

  fileprivate func didFail(_ error: Error?) {
    self.player = nil
    let pending = continuation
    continuation = nil
    pending?.resume(
      throwing: error ?? MiddleAIError.invalidResponse("Audio konnte nicht dekodiert werden"))
  }
}

private final class SpeechAudioRenderer: @unchecked Sendable {
  private let lock = NSLock()
  private let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "middleai-system-voice-\(UUID().uuidString).caf")
  private var file: AVAudioFile?
  private var continuation: CheckedContinuation<URL, Error>?
  private var completed = false

  @MainActor func render(_ utterance: AVSpeechUtterance, with synthesizer: AVSpeechSynthesizer)
    async throws
    -> URL
  {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      self.continuation = continuation
      lock.unlock()
      synthesizer.write(utterance) { [self] buffer in consume(buffer) }
    }
  }

  private func consume(_ buffer: AVAudioBuffer) {
    lock.lock()
    defer { lock.unlock() }
    guard !completed else { return }
    guard let pcm = buffer as? AVAudioPCMBuffer else {
      complete(.failure(MiddleAIError.invalidResponse("Systemstimme lieferte kein PCM-Audio")))
      return
    }
    if pcm.frameLength == 0 {
      complete(.success(url))
      return
    }
    do {
      if file == nil { file = try AVAudioFile(forWriting: url, settings: pcm.format.settings) }
      try file?.write(from: pcm)
    } catch { complete(.failure(error)) }
  }

  private func complete(_ result: Result<URL, Error>) {
    completed = true
    file = nil
    let pending = continuation
    continuation = nil
    pending?.resume(with: result)
  }
}

extension AudioFilePlayer: @preconcurrency AVAudioPlayerDelegate {
  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    didFinish(successfully: flag)
  }
  func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    didFail(error)
  }
}

public struct TTSVoiceDescriptor: Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let description: String
  public let isFemale: Bool
  public let isRecommended: Bool

  public init(
    id: String, name: String, description: String, isFemale: Bool,
    isRecommended: Bool = false
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.isFemale = isFemale
    self.isRecommended = isRecommended
  }
}

public enum TTSVoiceCatalog {
  public static let germanSample =
    "Guten Tag. Ich bin die ausgewählte Stimme von MiddleAI. Ein Python Workflow kann zum Beispiel 3,5 Millionen Datensätze verarbeiten. Diese Hörprobe wird vollständig lokal auf deinem Mac erzeugt."

  public static func defaultVoice(for provider: String) -> String {
    switch provider.lowercased() {
    case "qwen3_tts": return "qwen_standard"
    case "voxtral_tts": return "de_female"
    case "supertonic3": return "F1"
    case "pockettts": return "anna"
    case "adaptive", "macos":
      return macOSVoices().first(where: { $0.isRecommended })?.id ?? "de-DE"
    default: return ""
    }
  }

  public static func voices(for provider: String) -> [TTSVoiceDescriptor] {
    switch provider.lowercased() {
    case "qwen3_tts": return qwenVoices
    case "voxtral_tts": return voxtralVoices
    case "supertonic3": return supertonicVoices
    case "pockettts": return pocketVoices
    case "adaptive", "macos": return macOSVoices()
    default: return []
    }
  }

  public static let qwenVoices: [TTSVoiceDescriptor] = [
    .init(
      id: "qwen_standard", name: "Clara · Standarddeutsch",
      description:
        "Weiblich, warm und professionell. Neutrale deutsche Aussprache mit natürlicher Satzmelodie.",
      isFemale: true, isRecommended: true),
    .init(
      id: "qwen_calm", name: "Sophie · Ruhig",
      description:
        "Weiblich, ruhig und klar. Für längere Erklärungen mit zurückhaltender Betonung.",
      isFemale: true),
    .init(
      id: "qwen_lively", name: "Mia · Lebendig",
      description: "Weiblich, freundlich und etwas lebhafter. Für kurze Antworten und Dialoge.",
      isFemale: true),
  ]

  public static let voxtralVoices: [TTSVoiceDescriptor] = [
    .init(
      id: "de_female", name: "Voxtral · Deutsch weiblich",
      description:
        "Natürliche deutsche Frauenstimme von Mistral. Nur für nicht-kommerzielle Nutzung lizenziert.",
      isFemale: true, isRecommended: true),
    .init(
      id: "neutral_female", name: "Voxtral · Neutral weiblich",
      description:
        "Neutrale mehrsprachige Frauenstimme. Deutsch wird unterstützt; nur nicht-kommerzielle Nutzung.",
      isFemale: true),
    .init(
      id: "cheerful_female", name: "Voxtral · Freundlich weiblich",
      description: "Lebhaftere mehrsprachige Frauenstimme. Nur für nicht-kommerzielle Nutzung.",
      isFemale: true),
  ]

  public static func qwenVoicePrompt(for id: String, rate: Float) -> String {
    let tempo: String
    if rate < 0.92 {
      tempo = "Sprich etwas langsamer und mit kurzen natürlichen Pausen."
    } else if rate > 1.08 {
      tempo = "Sprich zügig, aber weiterhin deutlich und flüssig."
    } else {
      tempo = "Sprich in natürlichem Gesprächstempo."
    }
    switch id {
    case "qwen_calm":
      return
        "Eine ruhige, klare erwachsene Frauenstimme mit neutralem Standarddeutsch, zurückhaltender Betonung und flüssiger Prosodie. \(tempo)"
    case "qwen_lively":
      return
        "Eine freundliche, lebendige junge Frauenstimme mit neutralem Standarddeutsch, warmer Klangfarbe und natürlicher ausdrucksstarker Betonung. \(tempo)"
    default:
      return
        "Eine warme, professionelle erwachsene Frauenstimme mit neutralem Standarddeutsch, präziser Aussprache und natürlicher flüssiger Satzmelodie. Englische Fachbegriffe werden authentisch ausgesprochen. \(tempo)"
    }
  }

  public static let supertonicVoices: [TTSVoiceDescriptor] = [
    .init(
      id: "F1", name: "F1",
      description:
        "Weiblicher Supertonic-Referenzstil 1. Mehrsprachig mit explizitem Deutschmodus; für MiddleAI empfohlen.",
      isFemale: true, isRecommended: true),
    .init(
      id: "F2", name: "F2",
      description:
        "Weiblicher Supertonic-Referenzstil 2 mit eigener Klangfarbe. Deutsch wird nativ vom mehrsprachigen Modell erzeugt.",
      isFemale: true),
    .init(
      id: "F3", name: "F3",
      description:
        "Weiblicher Supertonic-Referenzstil 3 mit eigener Klangfarbe. Lokal und für längere Antworten geeignet.",
      isFemale: true),
    .init(
      id: "F4", name: "F4",
      description:
        "Weiblicher Supertonic-Referenzstil 4 mit eigener Klangfarbe. Vollständig lokale 44,1-kHz-Ausgabe.",
      isFemale: true),
    .init(
      id: "F5", name: "F5",
      description:
        "Weiblicher Supertonic-Referenzstil 5 mit eigener Klangfarbe. Vollständig lokal auf Apple Silicon.",
      isFemale: true),
  ]

  public static let pocketVoices: [TTSVoiceDescriptor] = [
    .init(
      id: "anna", name: "Anna",
      description:
        "Weiblicher PocketTTS-Stil. Bei deutscher Sprache kann ein deutlicher Akzent hörbar sein.",
      isFemale: true),
    .init(
      id: "alba", name: "Alba",
      description:
        "Weiblicher PocketTTS-Stil; nicht speziell als deutsche Stimme aufgenommen, daher ist ein Akzent möglich.",
      isFemale: true),
    .init(
      id: "eve", name: "Eve",
      description:
        "Weiblicher PocketTTS-Stil mit alternativer Klangfarbe; deutscher Akzent ist möglich.",
      isFemale: true),
    .init(
      id: "jane", name: "Jane",
      description:
        "Weiblicher PocketTTS-Stil mit alternativer Klangfarbe; deutscher Akzent ist möglich.",
      isFemale: true),
    .init(
      id: "mary", name: "Mary",
      description:
        "Weiblicher PocketTTS-Stil mit alternativer Klangfarbe; deutscher Akzent ist möglich.",
      isFemale: true),
    .init(
      id: "vera", name: "Vera",
      description:
        "Weiblicher PocketTTS-Stil mit alternativer Klangfarbe; deutscher Akzent ist möglich.",
      isFemale: true),
    .init(
      id: "juergen", name: "Jürgen",
      description: "Männlicher, deutschsprachiger PocketTTS-Referenzstil.",
      isFemale: false),
  ]

  public static func macOSVoices() -> [TTSVoiceDescriptor] {
    let installed = AVSpeechSynthesisVoice.speechVoices()
      .filter { $0.language.hasPrefix("de") }
    let recommendedID = installed.sorted {
      if ($0.gender == .female) != ($1.gender == .female) {
        return $0.gender == .female
      }
      if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
      return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }.first?.identifier
    return
      installed
      .map { voice in
        let gender: String
        switch voice.gender {
        case .female: gender = "Weiblich"
        case .male: gender = "Männlich"
        default: gender = "Charakterstimme"
        }
        let quality: String
        switch voice.quality {
        case .premium: quality = "Premiumqualität"
        case .enhanced: quality = "Erweiterte Qualität"
        default:
          quality =
            voice.identifier.contains("compact")
            ? "Kompakte Systemstimme" : "Standardqualität"
        }
        return TTSVoiceDescriptor(
          id: voice.identifier, name: voice.name,
          description:
            "\(gender), \(voice.language), \(quality). Bereits in macOS installiert und offline verfügbar.",
          isFemale: voice.gender == .female,
          isRecommended: voice.identifier == recommendedID)
      }
      .sorted {
        if $0.isFemale != $1.isFemale { return $0.isFemale && !$1.isFemale }
        if $0.isRecommended != $1.isRecommended { return $0.isRecommended && !$1.isRecommended }
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
  }
}

public enum SpeechLanguage: String, Sendable {
  case german = "de"
  case english = "en"
}

public struct SpeechSegment: Equatable, Sendable {
  public let text: String
  public let language: SpeechLanguage

  public init(text: String, language: SpeechLanguage) {
    self.text = text
    self.language = language
  }
}

/// Local text preparation for smoother multilingual Supertonic speech.
public enum SpeechTextProcessor {
  private static let numberExpression = try! NSRegularExpression(
    pattern: #"(?<![\p{L}\p{N}])[-+]?\d+(?:[.,]\d+)*(?![\p{L}\p{N}])"#)
  private static let tokenExpression = try! NSRegularExpression(
    pattern: #"[\p{L}][\p{L}\p{M}'’\-]*|[^\p{L}]+"#)

  private static let explicitEnglishWords: Set<String> = [
    "ai", "api", "app", "apple", "assistant", "backend", "benchmark", "browser",
    "business", "chat", "cloud", "code", "command", "dashboard",
    "database", "deep", "desktop", "download", "edge", "engine", "feature", "feedback",
    "frontend", "github", "hardware", "interface", "island", "learning",
    "macbook", "macos", "management", "meeting", "middleai", "microsoft", "model",
    "notch", "openwebui", "plugin", "prompt", "python", "server", "settings", "shortcut",
    "software", "startup", "streaming", "team", "tool", "tools", "upload", "user",
    "voice", "web", "workflow", "workspace",
    "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "has", "in",
    "is", "it", "of", "on", "or", "that", "the", "this", "to", "with", "you",
  ]

  private static let germanOverrides: Set<String> = [
    "aber", "alle", "als", "also", "antwort", "auch", "auf", "aus", "bei", "beim",
    "bereits", "bis", "das", "dass", "dein", "dem", "den", "der", "des", "die", "dies",
    "diese", "dieser", "durch", "ein", "eine", "einer", "einen", "er", "es", "für", "ganz",
    "hat", "hier", "ich", "im", "ist", "kann", "kein", "keine", "mit", "nicht", "noch",
    "oder", "ohne", "schon", "sein", "sich", "sie", "sind", "und", "vom", "von", "vor",
    "war", "werden", "wie", "wird", "wir", "zu", "zum", "zur",
  ]

  private static let germanPronunciationAliases: [(String, String)] = [
    ("OpenWebUI", "Oupen Web Ju Ei"),
    ("MiddleAI", "Middel Ei Ai"),
    ("Microsoft", "Maikrosoft"),
    ("MacBook", "Mäckbuck"),
    ("Workflow", "Wörkfloh"),
    ("Feedback", "Fiedbäck"),
    ("Download", "Daunloud"),
    ("Upload", "Aploud"),
    ("Python", "Peiton"),
    ("GitHub", "Gitt Hab"),
    ("Cloud", "Klaud"),
    ("Chat", "Tschätt"),
    ("Voice", "Woiss"),
    ("AI", "Ei Ai"),
    ("API", "Ei Pi Ei"),
  ]

  public static func speechReadyGermanText(_ text: String) -> String {
    var result = normalizeGermanNumbers(in: SpokenResponseSummarizer.plainText(text))
    for (source, pronunciation) in germanPronunciationAliases {
      let escaped = NSRegularExpression.escapedPattern(for: source)
      guard
        let expression = try? NSRegularExpression(
          pattern: "(?i)(?<!\\p{L})\(escaped)(?!\\p{L})")
      else { continue }
      result = expression.stringByReplacingMatches(
        in: result, range: NSRange(result.startIndex..., in: result), withTemplate: pronunciation)
    }
    return result
  }

  public static func prefersPreciseGermanVoice(_ text: String) -> Bool {
    let clean = SpokenResponseSummarizer.plainText(text)
    if clean.count > 240 { return true }
    if clean.range(of: #"\d"#, options: .regularExpression) != nil { return true }
    let technicalTerms = germanPronunciationAliases.reduce(into: 0) { count, alias in
      if clean.range(of: alias.0, options: .caseInsensitive) != nil { count += 1 }
    }
    return technicalTerms >= 2
  }

  public static func segments(for text: String) -> [SpeechSegment] {
    let normalized = normalizeGermanNumbers(in: text)
    let fullRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
    var segments: [SpeechSegment] = []
    var pending = ""

    tokenExpression.enumerateMatches(in: normalized, range: fullRange) { match, _, _ in
      guard let match, let range = Range(match.range, in: normalized) else { return }
      let token = String(normalized[range])
      guard token.unicodeScalars.contains(where: CharacterSet.letters.contains) else {
        pending += token
        return
      }

      let language = language(for: token)
      if let last = segments.last, last.language == language {
        segments[segments.count - 1] = SpeechSegment(
          text: last.text + pending + token, language: language)
      } else {
        if !pending.isEmpty, let last = segments.last {
          segments[segments.count - 1] = SpeechSegment(
            text: last.text + pending, language: last.language)
          pending = ""
        }
        segments.append(SpeechSegment(text: token, language: language))
      }
      pending = ""
    }

    if !pending.isEmpty, let last = segments.last {
      segments[segments.count - 1] = SpeechSegment(
        text: last.text + pending, language: last.language)
    }
    return segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  public static func normalizeGermanNumbers(in text: String) -> String {
    var result = text
    let sourceRange = NSRange(text.startIndex..<text.endIndex, in: text)
    let matches = numberExpression.matches(in: text, range: sourceRange)

    for match in matches.reversed() {
      guard let range = Range(match.range, in: result) else { continue }
      let token = String(result[range])
      guard let replacement = spokenGermanNumber(token) else { continue }
      result.replaceSubrange(range, with: replacement)
    }
    return result.replacingOccurrences(of: "\u{00AD}", with: "")
  }

  private static func spokenGermanNumber(_ token: String) -> String? {
    var raw = token
    var prefix = ""
    if raw.first == "+" {
      prefix = "plus "
      raw.removeFirst()
    }
    guard !raw.hasPrefix("0") || raw == "0" || raw.hasPrefix("0,") else { return nil }

    let dots = raw.filter { $0 == "." }.count
    let commas = raw.filter { $0 == "," }.count
    let numeric: String
    if dots > 0, commas > 0 {
      if let lastComma = raw.lastIndex(of: ","), let lastDot = raw.lastIndex(of: "."),
        lastComma > lastDot
      {
        numeric = raw.replacingOccurrences(of: ".", with: "").replacingOccurrences(
          of: ",", with: ".")
      } else {
        numeric = raw.replacingOccurrences(of: ",", with: "")
      }
    } else if dots > 0 {
      let groups = raw.split(separator: ".", omittingEmptySubsequences: false)
      numeric =
        groups.count > 1 && groups.dropFirst().allSatisfy({ $0.count == 3 })
        ? groups.joined() : raw
    } else if commas > 1 {
      let groups = raw.split(separator: ",", omittingEmptySubsequences: false)
      numeric = groups.dropFirst().allSatisfy({ $0.count == 3 }) ? groups.joined() : raw
    } else {
      numeric = raw.replacingOccurrences(of: ",", with: ".")
    }

    guard let number = Decimal(string: numeric, locale: Locale(identifier: "en_US_POSIX")) else {
      return nil
    }
    let formatter = NumberFormatter()
    formatter.numberStyle = .spellOut
    formatter.locale = Locale(identifier: "de_DE")
    guard let words = formatter.string(from: number as NSDecimalNumber) else { return nil }
    return prefix + words.replacingOccurrences(of: "\u{00AD}", with: "")
  }

  private static func language(for word: String) -> SpeechLanguage {
    let lower = word.lowercased()
    if germanOverrides.contains(lower)
      || word.rangeOfCharacter(from: CharacterSet(charactersIn: "äöüßÄÖÜ")) != nil
    {
      return .german
    }
    if explicitEnglishWords.contains(lower) || isEnglishBrandStyle(word) { return .english }
    guard word.count >= 5 else { return .german }

    let recognizer = NLLanguageRecognizer()
    recognizer.processString(word)
    let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
    if (hypotheses[.english] ?? 0) >= 0.80, (hypotheses[.german] ?? 0) < 0.20 {
      return .english
    }
    return .german
  }

  private static func isEnglishBrandStyle(_ word: String) -> Bool {
    guard word.count >= 4 else { return false }
    let capitals = word.unicodeScalars.filter(CharacterSet.uppercaseLetters.contains).count
    let lowercase = word.unicodeScalars.filter(CharacterSet.lowercaseLetters.contains).count
    return capitals >= 2 && lowercase >= 1
  }
}

@MainActor public final class MacOSTTSProvider: NSObject, TTSProvider {
  private let synthesizer = AVSpeechSynthesizer()
  private let audioPlayer = AudioFilePlayer()
  private var continuation: CheckedContinuation<Void, Error>?
  public var voice: String
  public var rate: Float
  public init(voice: String = "", rate: Float = 1) {
    self.voice = voice
    self.rate = rate
    super.init()
    synthesizer.delegate = self
  }
  public var isSpeaking: Bool { synthesizer.isSpeaking || audioPlayer.isPlaying }
  public func speak(_ text: String) async throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    if isSpeaking { stop() }
    let utterance = AVSpeechUtterance(string: SpeechTextProcessor.speechReadyGermanText(text))
    utterance.voice = Self.resolveVoice(voice) ?? Self.bestInstalledGermanVoice()
    utterance.rate = max(
      AVSpeechUtteranceMinimumSpeechRate,
      min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * rate * 0.96))
    utterance.pitchMultiplier = 1.0
    if TTSOutputDevicePreference.uid == "system_default" {
      try await withCheckedThrowingContinuation { c in
        continuation = c
        synthesizer.speak(utterance)
      }
    } else {
      let renderer = SpeechAudioRenderer()
      let audioURL = try await renderer.render(utterance, with: synthesizer)
      defer { try? FileManager.default.removeItem(at: audioURL) }
      try await audioPlayer.play(audioURL)
    }
  }
  public func stop() {
    synthesizer.stopSpeaking(at: .immediate)
    audioPlayer.stop()
    continuation?.resume()
    continuation = nil
  }
  public static func bestInstalledGermanVoice() -> AVSpeechSynthesisVoice? {
    AVSpeechSynthesisVoice.speechVoices()
      .filter { $0.language.hasPrefix("de") }
      .sorted {
        if ($0.gender == .female) != ($1.gender == .female) {
          return $0.gender == .female
        }
        if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
      .first
  }

  public static func resolveVoice(_ selection: String) -> AVSpeechSynthesisVoice? {
    guard !selection.isEmpty else { return nil }
    return AVSpeechSynthesisVoice(identifier: selection)
      ?? AVSpeechSynthesisVoice.speechVoices().first {
        $0.name.localizedCaseInsensitiveCompare(selection) == .orderedSame
      }
      ?? AVSpeechSynthesisVoice(language: selection)
  }
}

extension MacOSTTSProvider: @preconcurrency AVSpeechSynthesizerDelegate {
  public func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) {
    continuation?.resume()
    continuation = nil
  }
  public func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    continuation?.resume()
    continuation = nil
  }
}

@MainActor public final class PocketTTSProvider: NSObject, TTSProvider {
  private let manager: PocketTtsManager
  private let voice: String
  private let temperature: Float
  private let audioPlayer = AudioFilePlayer()
  private var temporaryAudioURL: URL?
  private var initializationTask: Task<Void, Error>?
  private var initialized = false
  private var generation: UInt64 = 0
  private var isPreparing = false

  public init(voice: String = "anna", highQuality: Bool = true, temperature: Float = 0.65) {
    self.voice = voice.isEmpty ? "anna" : voice
    self.temperature = min(max(temperature, 0.1), 1.2)
    self.manager = PocketTtsManager(
      defaultVoice: voice.isEmpty ? "anna" : voice,
      language: highQuality ? .german24L : .german,
      precision: .int8,
      placement: .gpu)
    super.init()
  }

  public var isSpeaking: Bool { isPreparing || audioPlayer.isPlaying }

  public func prepare() async throws {
    try await ensureInitialized()
  }

  public func render(_ text: String) async throws -> Data {
    try await ensureInitialized()
    return try await manager.synthesize(
      text: text, voice: voice, temperature: temperature, deEss: true)
  }

  public func speak(_ text: String) async throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    stop()
    generation &+= 1
    let currentGeneration = generation
    isPreparing = true
    do {
      let audio = try await render(text)
      try Task.checkCancellation()
      guard generation == currentGeneration else { throw CancellationError() }
      let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "middleai-pockettts-\(UUID().uuidString).wav")
      try audio.write(to: audioURL, options: .atomic)
      temporaryAudioURL = audioURL
      defer { cleanupTemporaryAudio() }
      isPreparing = false
      try await audioPlayer.play(audioURL)
    } catch {
      isPreparing = false
      throw error
    }
  }

  public func stop() {
    generation &+= 1
    audioPlayer.stop()
    cleanupTemporaryAudio()
    isPreparing = false
  }

  private func cleanupTemporaryAudio() {
    if let temporaryAudioURL { try? FileManager.default.removeItem(at: temporaryAudioURL) }
    temporaryAudioURL = nil
  }

  private func ensureInitialized() async throws {
    if initialized { return }
    if let initializationTask {
      try await initializationTask.value
      initialized = true
      return
    }
    let task = Task { try await manager.initialize() }
    initializationTask = task
    do {
      try await task.value
      initialized = true
      initializationTask = nil
    } catch {
      initializationTask = nil
      throw error
    }
  }
}

@MainActor public final class Supertonic3TTSProvider: NSObject, TTSProvider {
  private let manager = Supertonic3Manager()
  private let voice: Supertonic3Voice
  private let speed: Float
  private let totalSteps: Int
  private var style: Supertonic3VoiceStyle?
  private let audioPlayer = AudioFilePlayer()
  private var temporaryAudioURL: URL?
  private var initializationTask: Task<Void, Error>?
  private var initialized = false
  private var generation: UInt64 = 0
  private var isPreparing = false

  public init(voice: String = "F1", rate: Float = 1, highQuality: Bool = true) {
    self.voice = Supertonic3Voice(name: voice) ?? .f1
    self.speed = min(max(rate, 0.55), 1.9)
    self.totalSteps = highQuality ? 12 : 6
    super.init()
  }

  public var isSpeaking: Bool { isPreparing || audioPlayer.isPlaying }

  public func prepare() async throws {
    try await ensureInitialized()
  }

  public func render(_ text: String) async throws -> Data {
    try await ensureInitialized()
    guard let style else {
      throw MiddleAIError.invalidResponse("Supertonic voice style is unavailable")
    }
    let prepared = SpeechTextProcessor.speechReadyGermanText(text)
    let result = try await manager.synthesize(
      text: prepared, language: "de", style: style, totalSteps: totalSteps,
      speed: speed, silenceDuration: 0.12)
    return try AudioWAV.data(
      from: result.samples, sampleRate: Double(Supertonic3Constants.sampleRate), normalize: false)
  }

  public func speak(_ text: String) async throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    stop()
    generation &+= 1
    let currentGeneration = generation
    isPreparing = true
    do {
      let audio = try await render(text)
      try Task.checkCancellation()
      guard generation == currentGeneration else { throw CancellationError() }
      let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "middleai-supertonic3-\(UUID().uuidString).wav")
      try audio.write(to: audioURL, options: .atomic)
      temporaryAudioURL = audioURL
      defer { cleanupTemporaryAudio() }
      isPreparing = false
      try await audioPlayer.play(audioURL)
    } catch {
      isPreparing = false
      throw error
    }
  }

  public func stop() {
    generation &+= 1
    audioPlayer.stop()
    cleanupTemporaryAudio()
    isPreparing = false
  }

  private func cleanupTemporaryAudio() {
    if let temporaryAudioURL { try? FileManager.default.removeItem(at: temporaryAudioURL) }
    temporaryAudioURL = nil
  }

  private func ensureInitialized() async throws {
    if initialized { return }
    if let initializationTask {
      try await initializationTask.value
      initialized = true
      return
    }
    let selectedVoice = voice
    let task = Task { [manager] in
      try await manager.initialize()
      let loadedStyle = try await Supertonic3ResourceDownloader.loadVoiceStyle(selectedVoice)
      await MainActor.run { [weak self] in self?.style = loadedStyle }
    }
    initializationTask = task
    do {
      try await task.value
      initialized = true
      initializationTask = nil
    } catch {
      initializationTask = nil
      throw error
    }
  }
}

/// Uses the expressive local model for short replies and the system's best installed
/// female German voice for long, numeric, or terminology-heavy answers. Both paths are offline.
@MainActor public final class AdaptiveGermanTTSProvider: TTSProvider {
  private let natural: any TTSProvider
  private let precise: any TTSProvider

  public init(natural: any TTSProvider, precise: any TTSProvider) {
    self.natural = natural
    self.precise = precise
  }

  public var isSpeaking: Bool { natural.isSpeaking || precise.isSpeaking }

  public func prepare() async throws {
    // The precise Apple path is immediately available. Failure to prepare the optional
    // natural model must therefore never disable speech.
    try? await natural.prepare()
  }

  public func speak(_ text: String) async throws {
    if SpeechTextProcessor.prefersPreciseGermanVoice(text) {
      try await precise.speak(text)
    } else {
      do { try await natural.speak(text) } catch { try await precise.speak(text) }
    }
  }

  public func stop() {
    natural.stop()
    precise.stop()
  }
}

/// Native Apple-Silicon inference for Qwen3-TTS VoiceDesign. The model is downloaded
/// once through Hugging Face and then runs entirely on-device through MLX.
private struct SendableSpeechGenerationModel: @unchecked Sendable {
  let raw: any SpeechGenerationModel

  var sampleRate: Int { raw.sampleRate }

  func generateSamples(text: String, voice: String) async throws -> [Float] {
    let audio = try await raw.generate(
      text: text, voice: voice, refAudio: nil, refText: nil, language: "German",
      generationParameters: nil)
    return audio.asArray(Float.self)
  }
}

@MainActor public final class Qwen3TTSProvider: TTSProvider {
  private static let modelRepository =
    "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-4bit"

  private let voicePrompt: String
  private var model: SendableSpeechGenerationModel?
  private let audioPlayer = AudioFilePlayer()
  private var temporaryAudioURL: URL?
  private var generation: UInt64 = 0
  private var isPreparing = false

  public init(voice: String, rate: Float, temperature: Float = 0.72) {
    self.voicePrompt = TTSVoiceCatalog.qwenVoicePrompt(for: voice, rate: rate)
    _ = temperature
  }

  public var isSpeaking: Bool { isPreparing || audioPlayer.isPlaying }

  public func prepare() async throws {
    _ = try await ensureModel()
  }

  public func speak(_ text: String) async throws {
    let clean = SpokenResponseSummarizer.plainText(text)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    stop()
    generation &+= 1
    let currentGeneration = generation
    isPreparing = true
    do {
      let loadedModel = try await ensureModel()
      let samples = try await loadedModel.generateSamples(text: clean, voice: voicePrompt)
      try Task.checkCancellation()
      guard generation == currentGeneration else { throw CancellationError() }
      let wav = try AudioWAV.data(
        from: samples, sampleRate: Double(loadedModel.sampleRate), normalize: false)
      let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "middleai-qwen3-tts-\(UUID().uuidString).wav")
      try wav.write(to: audioURL, options: Data.WritingOptions.atomic)
      temporaryAudioURL = audioURL
      defer { cleanupTemporaryAudio() }
      isPreparing = false
      try await audioPlayer.play(audioURL)
    } catch {
      isPreparing = false
      throw error
    }
  }

  public func stop() {
    generation &+= 1
    audioPlayer.stop()
    cleanupTemporaryAudio()
    isPreparing = false
  }

  private func ensureModel() async throws -> SendableSpeechGenerationModel {
    if let model { return model }
    let loaded = try await TTS.loadModel(modelRepo: Self.modelRepository)
    let wrapped = SendableSpeechGenerationModel(raw: loaded)
    model = wrapped
    return wrapped
  }

  private func cleanupTemporaryAudio() {
    if let temporaryAudioURL { try? FileManager.default.removeItem(at: temporaryAudioURL) }
    temporaryAudioURL = nil
  }
}

/// Mistral Voxtral TTS running locally through a MiddleAI-managed Python/MLX runtime.
/// The persistent worker keeps the 4-bit model in memory between utterances.
@MainActor public final class VoxtralTTSProvider: TTSProvider {
  private static let uvVersion = "0.11.32"
  private static let uvSHA256 =
    "ed336d0ba49db8ef89b2b41fffa372ce63bd032f22a56f001c265891aec32829"
  private static let mlxAudioVersion = "0.4.6"
  private static let mistralCommonVersion = "1.11.7"
  private static let runtimeSchemaVersion = "1"

  private let engine: String
  private let modelRepository: String
  private let voice: String
  private let voicePrompt: String
  private let rate: Float
  private var runnerProcess: Process?
  private var runnerInput: FileHandle?
  private var runnerOutput: Pipe?
  private var runnerError: Pipe?
  private var outputBuffer = Data()
  private var ready = false
  private var isPreparing = false
  private var readyContinuation: CheckedContinuation<Void, Error>?
  private var generationContinuation: CheckedContinuation<URL, Error>?
  private let audioPlayer = AudioFilePlayer()
  private var temporaryAudioURL: URL?

  public init(voice: String) {
    self.engine = "voxtral_tts"
    self.modelRepository = "mlx-community/Voxtral-4B-TTS-2603-mlx-4bit"
    self.voice =
      TTSVoiceCatalog.voxtralVoices.contains(where: { $0.id == voice })
      ? voice : "de_female"
    self.voicePrompt = ""
    self.rate = 1
  }

  private init(
    engine: String, modelRepository: String, voice: String, voicePrompt: String, rate: Float
  ) {
    self.engine = engine
    self.modelRepository = modelRepository
    self.voice = voice
    self.voicePrompt = voicePrompt
    self.rate = rate
  }

  public static func qwen(voice: String, rate: Float) -> VoxtralTTSProvider {
    VoxtralTTSProvider(
      engine: "qwen3_tts",
      modelRepository: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-4bit",
      voice: "",
      voicePrompt: TTSVoiceCatalog.qwenVoicePrompt(for: voice, rate: rate),
      rate: rate)
  }

  public var isSpeaking: Bool {
    isPreparing || generationContinuation != nil || audioPlayer.isPlaying
  }

  public func prepare() async throws {
    try await ensureRunner()
  }

  public func speak(_ text: String) async throws {
    let clean = SpokenResponseSummarizer.plainText(text)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    stopPlayback()
    try await ensureRunner()

    let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "middleai-voxtral-\(UUID().uuidString).wav")
    temporaryAudioURL = audioURL
    let payload: [String: Any] = [
      "action": "speak", "text": clean, "voice": voice, "instruct": voicePrompt,
      "rate": rate, "output": audioURL.path,
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    guard let input = runnerInput else {
      throw MiddleAIError.invalidResponse("Voxtral-Prozess ist nicht erreichbar")
    }
    _ = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<URL, Error>) in
      generationContinuation = continuation
      do {
        try input.write(contentsOf: data + Data([0x0A]))
      } catch {
        generationContinuation = nil
        continuation.resume(throwing: error)
      }
    }
    try Task.checkCancellation()
    try await play(audioURL)
  }

  public func stop() {
    stopPlayback()
    if generationContinuation != nil || isPreparing {
      terminateRunner(error: CancellationError())
    }
  }

  private func ensureRunner() async throws {
    if ready, runnerProcess?.isRunning == true { return }
    if isPreparing {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        readyContinuation = continuation
      }
      return
    }
    isPreparing = true
    let python: URL
    do {
      python = try await ensureRuntime()
    } catch {
      isPreparing = false
      throw error
    }
    guard
      let runnerURL = Bundle.module.url(
        forResource: "voxtral_runner", withExtension: "py")
    else {
      isPreparing = false
      throw MiddleAIError.configuration("Der Voxtral-Runner fehlt im App-Bundle")
    }

    let process = Process()
    let output = Pipe()
    let errorOutput = Pipe()
    let input = Pipe()
    process.executableURL = python
    process.arguments = [runnerURL.path, modelRepository, engine]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errorOutput
    runnerProcess = process
    runnerInput = input.fileHandleForWriting
    runnerOutput = output
    runnerError = errorOutput
    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      Task { @MainActor in self?.consumeRunnerOutput(data) }
    }
    process.terminationHandler = { [weak self] ended in
      Task { @MainActor in
        guard let self, self.runnerProcess === ended else { return }
        let details =
          String(
            data: errorOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let message = details.trimmingCharacters(in: .whitespacesAndNewlines)
        self.terminateRunner(
          error: MiddleAIError.invalidResponse(
            message.isEmpty ? "Voxtral wurde unerwartet beendet" : String(message.suffix(900))))
      }
    }

    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      readyContinuation = continuation
      do {
        try process.run()
      } catch {
        readyContinuation = nil
        isPreparing = false
        continuation.resume(throwing: error)
      }
    }
  }

  private func consumeRunnerOutput(_ data: Data) {
    outputBuffer.append(data)
    while let newline = outputBuffer.firstRange(of: Data([0x0A])) {
      let lineData = outputBuffer[..<newline.lowerBound]
      outputBuffer.removeSubrange(...newline.lowerBound)
      guard let line = String(data: lineData, encoding: .utf8),
        line.hasPrefix("MIDDLEAI:"),
        let jsonData = line.dropFirst("MIDDLEAI:".count).data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
        let event = object["event"] as? String
      else { continue }
      switch event {
      case "ready":
        ready = true
        isPreparing = false
        readyContinuation?.resume()
        readyContinuation = nil
      case "generated":
        guard let path = object["path"] as? String else { continue }
        generationContinuation?.resume(returning: URL(fileURLWithPath: path))
        generationContinuation = nil
      case "error":
        let message = object["message"] as? String ?? "Unbekannter Voxtral-Fehler"
        let error = MiddleAIError.invalidResponse(message)
        if let generationContinuation {
          self.generationContinuation = nil
          generationContinuation.resume(throwing: error)
        } else {
          isPreparing = false
          readyContinuation?.resume(throwing: error)
          readyContinuation = nil
        }
      default: break
      }
    }
  }

  private func ensureRuntime() async throws -> URL {
    #if !arch(arm64)
      throw MiddleAIError.configuration("Voxtral TTS benötigt einen Apple-Silicon-Mac")
    #else
      let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".middleai/runtime", isDirectory: true)
      let runtimeRoot = root.appendingPathComponent("voxtral", isDirectory: true)
      try Self.recoverInterruptedRuntime(in: root, installed: runtimeRoot)
      let installedPython = runtimeRoot.appendingPathComponent(".venv/bin/python")
      if FileManager.default.isExecutableFile(atPath: installedPython.path),
        try await Self.verifyRuntime(installedPython)
      {
        try Self.writeRuntimeManifest(at: runtimeRoot)
        return installedPython
      }

      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let uv = root.appendingPathComponent("bin/uv")
      if !FileManager.default.isExecutableFile(atPath: uv.path) {
        try await installUV(uv, root: root)
      }
      guard
        let requirements = Bundle.module.url(
          forResource: "tts-runtime-requirements", withExtension: "txt")
      else { throw MiddleAIError.configuration("Die gepinnte TTS-Laufzeitdefinition fehlt") }

      let environment = ["UV_NO_MODIFY_PATH": "1"]
      let stagingRoot = root.appendingPathComponent(
        "voxtral.partial.\(UUID().uuidString)", isDirectory: true)
      let stagedVenv = stagingRoot.appendingPathComponent(".venv", isDirectory: true)
      let stagedPython = stagedVenv.appendingPathComponent("bin/python")
      try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: stagingRoot) }

      var result = try await Self.run(
        uv, arguments: ["venv", "--python", "3.12", stagedVenv.path], environment: environment)
      guard result.status == 0 else { throw Self.runtimeError(result.output) }
      result = try await Self.run(
        uv,
        arguments: [
          "pip", "install", "--quiet", "--require-hashes", "--python", stagedPython.path,
          "--requirements", requirements.path,
        ], environment: environment)
      guard result.status == 0 else { throw Self.runtimeError(result.output) }
      guard try await Self.verifyRuntime(stagedPython) else {
        throw MiddleAIError.invalidResponse(
          "Die installierte TTS-Laufzeit hat den Versions- und Importtest nicht bestanden")
      }
      try Self.writeRuntimeManifest(at: stagingRoot)
      try Self.activateRuntime(stagingRoot, replacing: runtimeRoot)
      return runtimeRoot.appendingPathComponent(".venv/bin/python")
    #endif
  }

  private static func verifyRuntime(_ python: URL) async throws -> Bool {
    let script = """
      import importlib.metadata as m
      import mlx_audio, mistral_common
      assert m.version('mlx-audio') == '\(mlxAudioVersion)'
      assert m.version('mistral-common') == '\(mistralCommonVersion)'
      """
    return try await run(python, arguments: ["-c", script]).status == 0
  }

  private static func writeRuntimeManifest(at root: URL) throws {
    let values = [
      "schema": runtimeSchemaVersion,
      "python": "3.12",
      "mlx-audio": mlxAudioVersion,
      "mistral-common": mistralCommonVersion,
      "requirements": "tts-runtime-requirements.txt",
    ]
    let data = try JSONSerialization.data(
      withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: root.appendingPathComponent("runtime-manifest.json"), options: .atomic)
  }

  private static func activateRuntime(_ staged: URL, replacing installed: URL) throws {
    let fileManager = FileManager.default
    let backup = installed.deletingLastPathComponent().appendingPathComponent(
      "voxtral.backup.\(UUID().uuidString)", isDirectory: true)
    let hadInstalledRuntime = fileManager.fileExists(atPath: installed.path)
    if hadInstalledRuntime { try fileManager.moveItem(at: installed, to: backup) }
    do {
      try fileManager.moveItem(at: staged, to: installed)
      if hadInstalledRuntime { try? fileManager.removeItem(at: backup) }
    } catch {
      if hadInstalledRuntime && !fileManager.fileExists(atPath: installed.path) {
        try? fileManager.moveItem(at: backup, to: installed)
      }
      throw error
    }
  }

  private static func recoverInterruptedRuntime(in root: URL, installed: URL) throws {
    guard FileManager.default.fileExists(atPath: root.path) else { return }
    let candidates = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles])
    let backups = candidates.filter { $0.lastPathComponent.hasPrefix("voxtral.backup.") }
      .sorted {
        let left =
          (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? .distantPast
        let right =
          (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? .distantPast
        return left > right
      }
    if !FileManager.default.fileExists(atPath: installed.path), let newest = backups.first {
      try FileManager.default.moveItem(at: newest, to: installed)
    }
    for backup in backups where FileManager.default.fileExists(atPath: backup.path) {
      try? FileManager.default.removeItem(at: backup)
    }
    // Old staging directories are never used across launches. Keep recent directories in
    // case a CLI process and the app are preparing the shared runtime concurrently.
    for partial in candidates where partial.lastPathComponent.hasPrefix("voxtral.partial.") {
      let changed =
        (try? partial.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? .distantPast
      if Date().timeIntervalSince(changed) > 3_600 {
        try? FileManager.default.removeItem(at: partial)
      }
    }
  }

  private func installUV(_ destination: URL, root: URL) async throws {
    let archiveURL = URL(
      string:
        "https://github.com/astral-sh/uv/releases/download/\(Self.uvVersion)/uv-aarch64-apple-darwin.tar.gz"
    )!
    let (data, response) = try await URLSession.shared.data(from: archiveURL)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw MiddleAIError.invalidResponse("Die lokale Voxtral-Laufzeit konnte nicht geladen werden")
    }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard digest == Self.uvSHA256 else {
      throw MiddleAIError.invalidResponse("Die Prüfsumme der Voxtral-Laufzeit stimmt nicht")
    }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "middleai-uv-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let archive = temporary.appendingPathComponent("uv.tar.gz")
    try data.write(to: archive, options: .atomic)
    let extracted = try await Self.run(
      URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xzf", archive.path, "-C", temporary.path])
    guard extracted.status == 0 else { throw Self.runtimeError(extracted.output) }
    let source = temporary.appendingPathComponent("uv-aarch64-apple-darwin/uv")
    let stagedDestination = destination.deletingLastPathComponent().appendingPathComponent(
      "uv.partial.\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: stagedDestination) }
    try FileManager.default.copyItem(at: source, to: stagedDestination)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: stagedDestination.path)
    try FileManager.default.moveItem(at: stagedDestination, to: destination)
  }

  private static func run(
    _ executable: URL, arguments: [String], environment: [String: String] = [:]
  ) async throws -> (status: Int32, output: String) {
    try await withCheckedThrowingContinuation { continuation in
      let process = Process()
      let pipe = Pipe()
      process.executableURL = executable
      process.arguments = arguments
      process.standardOutput = pipe
      process.standardError = pipe
      process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new
      }
      process.terminationHandler = { ended in
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        continuation.resume(
          returning: (ended.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
      }
      do { try process.run() } catch { continuation.resume(throwing: error) }
    }
  }

  private static func runtimeError(_ output: String) -> Error {
    MiddleAIError.invalidResponse(
      output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "Die lokale Voxtral-Laufzeit konnte nicht eingerichtet werden"
        : String(output.suffix(900)))
  }

  private func play(_ url: URL) async throws {
    defer { cleanupTemporaryAudio() }
    try await audioPlayer.play(url)
  }

  private func stopPlayback() {
    audioPlayer.stop()
    cleanupTemporaryAudio()
  }

  private func terminateRunner(error: Error) {
    runnerOutput?.fileHandleForReading.readabilityHandler = nil
    runnerProcess?.terminationHandler = nil
    if runnerProcess?.isRunning == true { runnerProcess?.terminate() }
    runnerProcess = nil
    runnerInput = nil
    runnerOutput = nil
    runnerError = nil
    outputBuffer.removeAll(keepingCapacity: true)
    ready = false
    isPreparing = false
    readyContinuation?.resume(throwing: error)
    readyContinuation = nil
    generationContinuation?.resume(throwing: error)
    generationContinuation = nil
  }

  private func cleanupTemporaryAudio() {
    if let temporaryAudioURL { try? FileManager.default.removeItem(at: temporaryAudioURL) }
    temporaryAudioURL = nil
  }
}

@MainActor public final class LocalModelTTSProvider: TTSProvider {
  private let executable: String
  private var process: Process?
  public init(executable: String) { self.executable = executable }
  public var isSpeaking: Bool { process?.isRunning == true }
  public func speak(_ text: String) async throws {
    guard !executable.isEmpty, FileManager.default.isExecutableFile(atPath: executable) else {
      throw MiddleAIError.configuration("Local TTS executable is unavailable")
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = [text]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    process = p
    await withCheckedContinuation { c in p.terminationHandler = { _ in c.resume() } }
  }
  public func stop() {
    process?.terminate()
    process = nil
  }
}

@MainActor public final class FallbackTTSProvider: TTSProvider {
  private let primary: any TTSProvider
  private let fallback: any TTSProvider
  public init(primary: any TTSProvider, fallback: any TTSProvider) {
    self.primary = primary
    self.fallback = fallback
  }
  public var isSpeaking: Bool { primary.isSpeaking || fallback.isSpeaking }
  public func prepare() async throws {
    try await primary.prepare()
  }
  public func speak(_ text: String) async throws {
    do {
      try await primary.speak(text)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Task.checkCancellation()
      try await fallback.speak(text)
    }
  }
  public func stop() {
    primary.stop()
    fallback.stop()
  }
}

@MainActor public final class TTSQueue {
  private let provider: any TTSProvider
  private var pending: [String] = []
  private var task: Task<Void, Never>?
  private var taskGeneration: UInt64 = 0
  public private(set) var enabled: Bool
  public init(provider: any TTSProvider, enabled: Bool = true) {
    self.provider = provider
    self.enabled = enabled
  }
  public var isSpeaking: Bool { task != nil || provider.isSpeaking || !pending.isEmpty }
  public func prepare() async throws { try await provider.prepare() }
  public func enqueue(_ sentence: String) {
    guard enabled else { return }
    pending.append(sentence)
    startIfNeeded()
  }
  public func setEnabled(_ value: Bool) {
    enabled = value
    if !value { stop() }
  }
  public func stop() {
    taskGeneration &+= 1
    pending.removeAll()
    provider.stop()
    task?.cancel()
    task = nil
  }
  public func waitUntilIdle() async throws {
    while isSpeaking {
      try Task.checkCancellation()
      try await Task.sleep(for: .milliseconds(40))
    }
  }
  private func startIfNeeded() {
    guard task == nil else { return }
    taskGeneration &+= 1
    let generation = taskGeneration
    task = Task { [weak self] in
      while let self, !Task.isCancelled, !self.pending.isEmpty {
        let next = self.pending.removeFirst()
        try? await self.provider.speak(next)
      }
      if self?.taskGeneration == generation { self?.task = nil }
    }
  }
}

@MainActor public final class ResponsePipeline {
  private let queue: TTSQueue
  private var buffer = SentenceBuffer()
  private var completeResponse = ""
  private let mode: String
  private var acceptedCount = 0
  public init(queue: TTSQueue, mode: String = "full") {
    self.queue = queue
    self.mode = mode
  }
  public func receive(_ token: String) {
    if mode == "full" {
      completeResponse += token
      return
    }
    if mode == "smart_summary" { return }
    for sentence in buffer.append(token) where shouldSpeak(sentence) {
      queue.enqueue(sentence)
      acceptedCount += 1
    }
  }
  public func finish() {
    if mode == "full" {
      let response = completeResponse.trimmingCharacters(in: .whitespacesAndNewlines)
      if !response.isEmpty { queue.enqueue(response) }
    } else if mode == "smart_summary" {
      // The completed answer is summarized locally by MiddleAIEngine.
    } else if let remainder = buffer.flush(), shouldSpeak(remainder) {
      queue.enqueue(remainder)
    }
    completeResponse = ""
    acceptedCount = 0
  }
  public func interrupt() {
    buffer = SentenceBuffer()
    completeResponse = ""
    acceptedCount = 0
    queue.stop()
  }
  private func shouldSpeak(_ sentence: String) -> Bool {
    switch mode {
    case "first_paragraph": return acceptedCount == 0
    case "summary", "smart_summary": return acceptedCount < 2
    default: return true
    }
  }
}
