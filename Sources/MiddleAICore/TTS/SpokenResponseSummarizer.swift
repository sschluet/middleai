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

  private let localLLM: AppConfig.LocalLLM?
  private let session: URLSession
  private let localCircuitBreaker: LocalLLMCircuitBreaker?
  private let systemModelEnabled: Bool

  public init(
    localLLM: AppConfig.LocalLLM? = nil, session: URLSession = .shared,
    systemModelEnabled: Bool = true
  ) {
    self.localLLM = localLLM
    self.session = session
    self.systemModelEnabled = systemModelEnabled
    if let localLLM, localLLM.enabled, ["ollama", "llama_cpp"].contains(localLLM.provider) {
      self.localCircuitBreaker = LocalLLMCircuitBreaker(
        failureThreshold: localLLM.circuitBreakerFailures,
        cooldown: localLLM.circuitBreakerCooldownSeconds)
    } else {
      self.localCircuitBreaker = nil
    }
  }

  public func spokenText(
    for response: String, threshold: Int = 850, maximumWords: Int = 110
  ) async -> String {
    let clean = Self.plainText(response)
    guard
      clean.count > threshold || clean.split(whereSeparator: \Character.isWhitespace).count > 150
    else { return clean }

    #if canImport(FoundationModels)
      if systemModelEnabled, #available(macOS 26.0, *) {
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
            if Self.isGroundedSummary(candidate, in: clean, maximumWords: maximumWords) {
              return candidate
            }
          } catch {
            // Deterministic local fallback below.
          }
        }
      }
    #endif

    if let localSummary = await summarizeWithLocalLLM(clean, maximumWords: maximumWords) {
      return localSummary
    }

    return Self.extractiveSummary(clean, maximumWords: maximumWords)
  }

  private func summarizeWithLocalLLM(_ clean: String, maximumWords: Int) async -> String? {
    guard let localLLM, let localCircuitBreaker,
      localLLM.enabled, ["ollama", "llama_cpp"].contains(localLLM.provider),
      let endpoint = URL(string: localLLM.url), endpoint.scheme == "http",
      ["localhost", "127.0.0.1", "::1"].contains(endpoint.host?.lowercased() ?? ""),
      await localCircuitBreaker.allowsRequest()
    else { return nil }

    do {
      let source = Self.boundedSummaryInput(clean)
      let payload: [String: Any] = [
        "model": localLLM.model,
        "stream": false,
        "temperature": 0,
        "messages": [
          [
            "role": "system",
            "content":
              "Fasse ausschließlich den gegebenen Text auf Deutsch zusammen. Bewahre wichtige Zahlen, Bedingungen, Risiken und nächste Schritte. Keine Einleitung, kein Markdown, keine erfundenen Fakten. Maximal \(maximumWords) Wörter und nur vollständige Sätze.",
          ],
          ["role": "user", "content": source],
        ],
      ]
      var request = URLRequest(url: LocalLLMEndpoint.completionsURL(from: endpoint))
      request.httpMethod = "POST"
      request.timeoutInterval = localLLM.timeoutSeconds
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: payload)
      let (data, response) = try await session.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200,
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let choices = root["choices"] as? [[String: Any]],
        let message = choices.first?["message"] as? [String: Any],
        let content = message["content"] as? String
      else { throw MiddleAIError.invalidResponse("Local summary response was invalid") }
      let candidate = Self.plainText(content)
      guard Self.isGroundedSummary(candidate, in: clean, maximumWords: maximumWords) else {
        throw MiddleAIError.invalidResponse("Local summary was not grounded")
      }
      await localCircuitBreaker.recordSuccess()
      return candidate
    } catch is CancellationError {
      return nil
    } catch {
      await localCircuitBreaker.recordFailure()
      return nil
    }
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

  public nonisolated static func isGroundedSummary(
    _ candidate: String, in source: String, maximumWords: Int
  ) -> Bool {
    let words = candidate.split(whereSeparator: \Character.isWhitespace)
    guard !candidate.isEmpty, candidate.count < source.count,
      words.count <= maximumWords + 10, endsAtSentenceBoundary(candidate)
    else { return false }
    let candidateNumbers = numberTokens(candidate)
    let sourceNumbers = Set(numberTokens(source))
    guard candidateNumbers.allSatisfy(sourceNumbers.contains) else { return false }
    let candidateTokens = TextSimilarity.tokens(candidate)
    guard !candidateTokens.isEmpty else { return false }
    let sourceTokens = Set(TextSimilarity.tokens(source))
    let grounded = candidateTokens.filter(sourceTokens.contains).count
    return Double(grounded) / Double(candidateTokens.count) >= 0.55
  }

  private nonisolated static func numberTokens(_ text: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: #"\b\d[\d.,]*\b"#) else {
      return []
    }
    return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
      Range($0.range, in: text).map { String(text[$0]) }
    }
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
