import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

public actor SpokenResponseSummarizer {
  private struct RankedSentence {
    let index: Int
    let text: String
    let score: Double
  }

  public init() {}

  public func spokenText(
    for response: String, threshold: Int = 850, maximumWords: Int = 110
  ) async -> String {
    let clean = Self.plainText(response)
    guard
      clean.count > threshold || clean.split(whereSeparator: \Character.isWhitespace).count > 150
    else { return clean }

    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) {
        let model = SystemLanguageModel(
          useCase: .general, guardrails: .permissiveContentTransformations)
        if model.availability == .available,
          model.supportsLocale(Locale(identifier: "de_DE"))
        {
          do {
            let summaryInput = Self.boundedSummaryInput(clean)
            let session = LanguageModelSession(
              model: model,
              instructions: """
                Du erstellst kurze deutsche Audio-Zusammenfassungen längerer Assistentenantworten. Nenne zuerst das Ergebnis oder die Kernaussage. Bewahre wichtige Zahlen, Bedingungen, Risiken und konkrete nächste Schritte. Verwende kurze, natürlich gesprochene Sätze ohne Markdown, Aufzählungszeichen, Quellenlisten oder Einleitung. Erfinde nichts. Maximal \(maximumWords) Wörter.
                """)
            let result = try await session.respond(
              to: """
                Fasse diese Antwort für die Sprachausgabe zusammen:

                <antwort>
                \(summaryInput)
                </antwort>
                """)
            let candidate = Self.plainText(result.content)
            if !candidate.isEmpty,
              candidate.count < clean.count,
              candidate.split(whereSeparator: \Character.isWhitespace).count <= maximumWords + 20,
              Self.endsAtSentenceBoundary(candidate)
            {
              return candidate
            }
          } catch {
            // Deterministic local fallback below.
          }
        }
      }
    #endif

    return Self.extractiveSummary(clean, maximumWords: maximumWords)
  }

  public nonisolated static func plainText(_ input: String) -> String {
    var text = input
    text = replacing(pattern: #"```[\s\S]*?```"#, in: text, with: " ")
    text = replacing(pattern: #"`([^`]+)`"#, in: text, with: "$1")
    text = replacing(pattern: #"!\[[^\]]*\]\([^\)]*\)"#, in: text, with: " ")
    text = replacing(pattern: #"\[([^\]]+)\]\([^\)]*\)"#, in: text, with: "$1")
    text = replacing(pattern: #"(?m)^\s{0,3}(?:#{1,6}|[-*+] |\d+[.)] )\s*"#, in: text, with: "")
    text = replacing(pattern: #"[*_~>]"#, in: text, with: "")
    text = replacing(pattern: #"\s*\n+\s*"#, in: text, with: ". ")
    text = replacing(pattern: #"\s{2,}"#, in: text, with: " ")
    text = replacing(pattern: #"(?:\.\s*){2,}"#, in: text, with: ". ")
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public nonisolated static func extractiveSummary(
    _ text: String, maximumWords: Int
  ) -> String {
    let rawSentences = text.components(
      separatedBy: try! NSRegularExpression(pattern: #"(?<=[.!?])\s+"#))
    let sentences = rawSentences.enumerated().compactMap { index, sentence -> (Int, String)? in
      let clean = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
      let words = clean.split(whereSeparator: \Character.isWhitespace)
      guard words.count >= 5, words.count <= 55 else { return nil }
      return (index, clean)
    }
    let keywords = [
      "ergebnis", "fazit", "zusammenfass", "empfehl", "entscheid", "wichtig", "kern",
      "risik", "prognose", "ausblick", "insgesamt", "daher", "folgerung", "nächst",
    ]
    let ranked: [RankedSentence] = sentences.map { index, sentence in
      let normalized = sentence.lowercased()
      var score = index == 0 ? 2.0 : (index < 3 ? 1.0 : 0)
      let keywordMatches = keywords.reduce(into: 0) { count, keyword in
        if normalized.contains(keyword) { count += 1 }
      }
      score += Double(keywordMatches) * 1.8
      if normalized.range(of: #"\d"#, options: .regularExpression) != nil { score += 0.5 }
      if normalized.contains(":") { score += 0.25 }
      return RankedSentence(index: index, text: sentence, score: score)
    }
    .sorted { lhs, rhs in
      lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score > rhs.score
    }

    var chosen: [(Int, String)] = []
    var wordCount = 0
    for sentence in ranked {
      let count = sentence.text.split(whereSeparator: \Character.isWhitespace).count
      guard wordCount + count <= maximumWords || chosen.isEmpty else { continue }
      chosen.append((sentence.index, sentence.text))
      wordCount += count
      if chosen.count >= 4 { break }
    }
    let result = chosen.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " ")
    return result.isEmpty
      ? sentenceSafeFallback(rawSentences, maximumWords: maximumWords) : result
  }

  private nonisolated static func sentenceSafeFallback(
    _ rawSentences: [String], maximumWords: Int
  ) -> String {
    let sentences = rawSentences.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    guard let first = sentences.first else { return "" }
    let words = first.split(whereSeparator: \Character.isWhitespace)
    if words.count <= max(220, maximumWords * 2) {
      return endsAtSentenceBoundary(first) ? first : first + "."
    }
    let bounded = words.prefix(max(20, maximumWords)).joined(separator: " ")
    return bounded + ". Die vollständige Antwort ist in MiddleAI sichtbar."
  }

  private nonisolated static func endsAtSentenceBoundary(_ text: String) -> Bool {
    text.range(of: #"[.!?][\"'”’)]*$"#, options: .regularExpression) != nil
  }

  private nonisolated static func boundedSummaryInput(_ text: String) -> String {
    let limit = 14_000
    guard text.count > limit else { return text }
    let prefix = text.prefix(9_000)
    let suffix = text.suffix(5_000)
    return
      "\(prefix)\n\n[Der Mittelteil wurde für die lokale Zusammenfassung gekürzt.]\n\n\(suffix)"
  }

  private nonisolated static func replacing(
    pattern: String, in input: String, with replacement: String
  ) -> String {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return input }
    return expression.stringByReplacingMatches(
      in: input, range: NSRange(input.startIndex..., in: input), withTemplate: replacement)
  }
}

extension String {
  fileprivate func components(separatedBy expression: NSRegularExpression) -> [String] {
    let range = NSRange(startIndex..., in: self)
    var result: [String] = []
    var start = startIndex
    for match in expression.matches(in: self, range: range) {
      guard let matchRange = Range(match.range, in: self) else { continue }
      result.append(String(self[start..<matchRange.lowerBound]))
      start = matchRange.upperBound
    }
    result.append(String(self[start...]))
    return result
  }
}
