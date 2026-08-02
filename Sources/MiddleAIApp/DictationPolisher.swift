import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

actor DictationPolisher {
  func polish(_ transcript: String, enabled: Bool) async -> String {
    let original = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard enabled, !original.isEmpty else { return original }
    let fallback = Self.basicCleanup(original)

    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) {
        let model = SystemLanguageModel(
          useCase: .general, guardrails: .permissiveContentTransformations)
        guard model.availability == .available,
          model.supportsLocale(Locale(identifier: "de_DE"))
        else { return fallback }

        do {
          let session = LanguageModelSession(
            model: model,
            instructions: """
              Du korrigierst deutsche Sprachdiktate streng inhaltstreu. Standardmäßig kopierst du die Formulierung wörtlich. Du darfst ausschließlich Fülllaute und unmittelbare Wiederholungen entfernen sowie Großschreibung, Zeichensetzung und eindeutig fehlerhafte Grammatik minimal korrigieren. Formuliere niemals um, ersetze keine Wörter durch Synonyme, ordne keine Aussagen neu und löse keine Mehrdeutigkeit selbst auf. Namen, Zahlen, Mengen, Verneinungen, Fachbegriffe, Produktnamen, Anrede, Ton und Aussageabsicht müssen exakt erhalten bleiben. Wenn eine Stelle unklar ist, übernimm sie unverändert. Ergänze keine Information. Antworte nur mit dem fertigen Text ohne Einleitung, Erklärung, Markdown oder Anführungszeichen.
              """)
          let response = try await session.respond(
            to: """
              Korrigiere dieses Diktat nur dort, wo es nach den Regeln zweifelsfrei erlaubt ist:

              <diktat>
              \(original)
              </diktat>
              """)
          if let accepted = Self.acceptedAIResult(response.content, original: original) {
            return accepted
          }
        } catch {
          return fallback
        }
      }
    #endif

    return fallback
  }

  nonisolated static var availabilityDescription: String {
    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) {
        let model = SystemLanguageModel.default
        guard model.supportsLocale(Locale(identifier: "de_DE")) else {
          return "Das lokale Apple-Modell unterstützt auf diesem Mac derzeit kein Deutsch."
        }
        switch model.availability {
        case .available:
          return "Apple Intelligence ist lokal verfügbar. Diktate verlassen den Mac nicht."
        case .unavailable(.appleIntelligenceNotEnabled):
          return "Apple Intelligence ist deaktiviert. Bis zur Aktivierung wird nur eine einfache lokale Bereinigung verwendet."
        case .unavailable(.modelNotReady):
          return "Das lokale Apple-Modell wird noch vorbereitet. Bis dahin wird eine einfache lokale Bereinigung verwendet."
        case .unavailable(.deviceNotEligible):
          return "Das lokale Apple-Modell ist auf diesem Mac nicht verfügbar. Es wird eine einfache lokale Bereinigung verwendet."
        case .unavailable:
          return "Das lokale Apple-Modell ist derzeit nicht verfügbar. Es wird eine einfache lokale Bereinigung verwendet."
        }
      }
    #endif
    return "Für die KI-Glättung ist macOS 26 mit Apple Intelligence erforderlich. Es wird eine einfache lokale Bereinigung verwendet."
  }

  nonisolated static func basicCleanup(_ input: String) -> String {
    var result = input.trimmingCharacters(in: .whitespacesAndNewlines)
    result = replacing(
      pattern: #"(?i)(?<!\p{L})(?:ähm+|äh+|hm+)(?!\p{L})[,.]?\s*"#,
      in: result, with: "")
    result = replacing(
      pattern: #"(?i)\b([\p{L}\p{N}]{2,})\b(?:[\s,]+\1\b)+"#,
      in: result, with: "$1")
    result = replacing(pattern: #"[ \t]+([,.;:!?])"#, in: result, with: "$1")
    result = replacing(pattern: #"[ \t]{2,}"#, in: result, with: " ")
    result = replacing(pattern: #"\s*\n\s*"#, in: result, with: " ")
    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = result.first else { return result }
    return first.uppercased() + result.dropFirst()
  }

  private nonisolated static func acceptedAIResult(
    _ candidate: String, original: String
  ) -> String? {
    var result = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.hasPrefix("```") {
      result = replacing(pattern: #"^```(?:text|markdown)?\s*|\s*```$"#, in: result, with: "")
    }
    result = replacing(
      pattern: #"(?i)^\s*(?:überarbeiteter text|geglättetes diktat|ergebnis)\s*:\s*"#,
      in: result, with: "")
    if result.count >= 2,
      (result.hasPrefix("\"") && result.hasSuffix("\""))
        || (result.hasPrefix("„") && result.hasSuffix("“"))
    {
      result.removeFirst()
      result.removeLast()
    }
    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !result.isEmpty else { return nil }
    let conservativeOriginal = basicCleanup(original)
    let ratio = Double(result.count) / Double(max(1, conservativeOriginal.count))
    guard ratio >= 0.72, ratio <= 1.28 else { return nil }
    guard protectedValues(in: conservativeOriginal).allSatisfy({ protected in
      result.range(of: protected, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }) else { return nil }
    guard numberValues(in: result) == numberValues(in: conservativeOriginal) else { return nil }

    let originalWords = meaningfulWords(in: conservativeOriginal)
    let candidateWords = meaningfulWords(in: result)
    if !originalWords.isEmpty {
      let retained = originalWords.intersection(candidateWords)
      let retention = Double(retained.count) / Double(originalWords.count)
      guard retention >= 0.78 else { return nil }
      let additions = candidateWords.subtracting(originalWords)
      let additionRatio = Double(additions.count) / Double(max(1, candidateWords.count))
      guard additionRatio <= 0.20 else { return nil }
    }
    return result
  }

  private nonisolated static func numberValues(in text: String) -> [String] {
    matches(pattern: #"(?<!\p{L})\d+(?:[.,]\d+)*(?!\p{L})"#, in: text)
      .map { $0.lowercased() }
      .sorted()
  }

  private nonisolated static func protectedValues(in text: String) -> Set<String> {
    let patterns = [
      #"(?i)\b(?:https?://|www\.)\S+"#,
      #"(?i)\b[\p{L}\p{N}._%+-]+@[\p{L}\p{N}.-]+\.[A-Z]{2,}\b"#,
      #"\b[A-ZÄÖÜ]{2,}[A-ZÄÖÜ0-9-]*\b"#,
      #"(?<![.!?]\s)\b[A-ZÄÖÜ][\p{L}-]{2,}\b"#,
    ]
    return Set(patterns.flatMap { matches(pattern: $0, in: text) })
  }

  private nonisolated static func meaningfulWords(in text: String) -> Set<String> {
    let ignored: Set<String> = [
      "aber", "also", "auch", "auf", "aus", "bei", "bin", "bis", "da", "das", "dass",
      "dem", "den", "der", "des", "die", "doch", "ein", "eine", "einem", "einen", "einer",
      "es", "für", "hat", "ich", "im", "in", "ist", "ja", "mal", "man", "mit", "noch",
      "oder", "quasi", "schon", "sehr", "sich", "so", "und", "von", "war", "wenn", "wie",
      "wir", "zu", "zum", "zur", "äh", "ähm", "hm",
    ]
    let tokens = matches(pattern: #"[\p{L}\p{N}][\p{L}\p{N}_-]*"#, in: text)
      .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
      .filter { $0.count >= 3 && !ignored.contains($0) }
    return Set(tokens)
  }

  private nonisolated static func matches(pattern: String, in text: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return expression.matches(in: text, range: range).compactMap { match in
      guard let swiftRange = Range(match.range, in: text) else { return nil }
      return String(text[swiftRange])
    }
  }

  private nonisolated static func replacing(
    pattern: String, in input: String, with replacement: String
  ) -> String {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return input }
    return expression.stringByReplacingMatches(
      in: input, range: NSRange(input.startIndex..., in: input), withTemplate: replacement)
  }
}
