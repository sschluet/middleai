import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

public actor SpokenResponseSummarizer {
  public init() {}

  public func spokenText(
    for response: String, threshold: Int = 850, maximumWords: Int = 110
  ) async -> String {
    let clean = Self.plainText(response)
    guard clean.count > threshold || clean.split(whereSeparator: \Character.isWhitespace).count > 150
    else { return clean }

    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) {
        let model = SystemLanguageModel(
          useCase: .general, guardrails: .permissiveContentTransformations)
        if model.availability == .available,
          model.supportsLocale(Locale(identifier: "de_DE"))
        {
          do {
            let session = LanguageModelSession(
              model: model,
              instructions: """
                Du erstellst kurze deutsche Audio-Zusammenfassungen längerer Assistentenantworten. Nenne zuerst das Ergebnis oder die Kernaussage. Bewahre wichtige Zahlen, Bedingungen, Risiken und konkrete nächste Schritte. Verwende kurze, natürlich gesprochene Sätze ohne Markdown, Aufzählungszeichen, Quellenlisten oder Einleitung. Erfinde nichts. Maximal (maximumWords) Wörter.
                """)
            let result = try await session.respond(
              to: """
                Fasse diese Antwort für die Sprachausgabe zusammen:

                <antwort>
                (clean)
                </antwort>
                """)
            let candidate = Self.plainText(result.content)
            if !candidate.isEmpty,
              candidate.count < clean.count,
              candidate.split(whereSeparator: \Character.isWhitespace).count <= maximumWords + 20
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

  private nonisolated static func extractiveSummary(
    _ text: String, maximumWords: Int
  ) -> String {
    let sentences = text.split(whereSeparator: { ".!?".contains($0) })
    var selected: [String] = []
    var wordCount = 0
    for sentence in sentences.prefix(6) {
      let clean = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
      let count = clean.split(whereSeparator: \Character.isWhitespace).count
      guard !clean.isEmpty, wordCount + count <= maximumWords || selected.isEmpty else { break }
      selected.append(clean)
      wordCount += count
      if selected.count >= 4 { break }
    }
    let result = selected.joined(separator: ". ")
    return result.isEmpty ? String(text.prefix(700)) : result + "."
  }

  private nonisolated static func replacing(
    pattern: String, in input: String, with replacement: String
  ) -> String {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return input }
    return expression.stringByReplacingMatches(
      in: input, range: NSRange(input.startIndex..., in: input), withTemplate: replacement)
  }
}
