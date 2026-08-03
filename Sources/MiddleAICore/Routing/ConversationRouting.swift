import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

public protocol ConversationRoutingStrategy: Sendable {
  func route(_ context: ConversationContext) async throws -> RoutingDecision
}

public struct TextSimilarity: Sendable {
  private static let stopwords: Set<String> = [
    "der", "die", "das", "den", "dem", "ein", "eine", "und", "oder", "ist", "sind", "war", "wie",
    "was", "noch", "mal", "mit", "zu", "von", "im", "in", "auf", "for", "the", "a", "an", "is",
    "are", "and", "or", "to", "of", "it",
  ]
  public static func tokens(_ text: String) -> [String] {
    text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { $0.count > 2 && !stopwords.contains($0) }
  }
  public static func cosine(_ lhs: String, _ rhs: String) -> Double {
    let a = frequencies(tokens(lhs))
    let b = frequencies(tokens(rhs))
    guard !a.isEmpty, !b.isEmpty else { return 0 }
    let dot = a.reduce(0.0) { $0 + Double($1.value * (b[$1.key] ?? 0)) }
    let na = sqrt(a.values.reduce(0.0) { $0 + Double($1 * $1) })
    let nb = sqrt(b.values.reduce(0.0) { $0 + Double($1 * $1) })
    return dot / (na * nb)
  }
  private static func frequencies(_ tokens: [String]) -> [String: Int] {
    tokens.reduce(into: [:]) { $0[$1, default: 0] += 1 }
  }
}

public struct HeuristicRouter: ConversationRoutingStrategy {
  public let continuationTimeout: TimeInterval
  public init(continuationTimeout: TimeInterval = 300) {
    self.continuationTimeout = continuationTimeout
  }

  public func route(_ context: ConversationContext) async throws -> RoutingDecision {
    guard let current = context.current else {
      return RoutingDecision(
        decision: .newChat, confidence: 0.98, reason: "No current conversation")
    }
    let normalizedInput = context.input.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      .lowercased()
    let newTopicMarkers = [
      "neues thema", "neue frage", "andere frage", "anderes thema", "themenwechsel",
      "unabhangig davon", "new topic", "new question", "different question",
      "switch topic", "unrelated question",
    ]
    if newTopicMarkers.contains(where: { normalizedInput.hasPrefix($0) }) {
      return RoutingDecision(
        decision: .newChat, confidence: 0.96,
        reason: "The input explicitly starts a new topic")
    }
    let currentText = searchableText(current, context.messages[current.id] ?? [])
    let currentSimilarity = TextSimilarity.cosine(context.input, currentText)
    let age = max(0, context.now.timeIntervalSince(current.lastUsedAt))
    let recency = exp(-age / max(60, continuationTimeout))
    let followUpMarkers = [
      "und ", "außerdem", "davon", "dazu", "nochmal", "noch mal", "welches davon",
      "wie sieht es mit", "warum", "wieso", "weshalb", "erklär", "erlauter",
      "kannst du das", "was meinst du", "mehr dazu", "genauer", "darauf", "dabei",
      "what about", "and ", "why", "explain", "can you", "tell me more",
    ]
    let followUp = followUpMarkers.contains { normalizedInput.hasPrefix($0) } ? 0.22 : 0
    let currentScore = min(0.99, currentSimilarity * 0.65 + recency * 0.30 + followUp)

    var bestOther: (Conversation, Double)?
    for conversation in context.recent where conversation.id != current.id {
      let similarity = TextSimilarity.cosine(
        context.input, searchableText(conversation, context.messages[conversation.id] ?? []))
      let candidateAge = max(0, context.now.timeIntervalSince(conversation.lastUsedAt))
      let score = similarity * 0.8 + exp(-candidateAge / 86_400) * 0.1
      if score > (bestOther?.1 ?? 0) { bestOther = (conversation, score) }
    }
    if let other = bestOther, other.1 > max(0.50, currentScore + 0.12) {
      return RoutingDecision(
        decision: .switchChat, chatID: other.0.id, confidence: min(0.95, other.1),
        reason: "A recent conversation is a stronger semantic match")
    }
    if age <= continuationTimeout {
      return RoutingDecision(
        decision: .continueCurrent, chatID: current.id, confidence: max(0.78, currentScore),
        reason: "The current conversation is inside the configured continuation window")
    }
    if currentScore >= 0.44 {
      return RoutingDecision(
        decision: .continueCurrent, chatID: current.id, confidence: max(0.56, currentScore),
        reason: "Recency and semantic continuation favor the current conversation")
    }
    let confidence = age > continuationTimeout ? 0.82 : 0.62
    return RoutingDecision(
      decision: .newChat, confidence: confidence,
      reason: "Input appears unrelated to recent conversation context")
  }
  private func searchableText(_ c: Conversation, _ messages: [Message]) -> String {
    ([c.title, c.summary] + messages.suffix(8).map(\.content)).joined(separator: " ")
  }
}

public struct EmbeddingRouter: ConversationRoutingStrategy {
  public init() {}
  public func route(_ context: ConversationContext) async throws -> RoutingDecision {
    guard !context.recent.isEmpty else {
      return RoutingDecision(
        decision: .newChat, confidence: 0.95, reason: "No embeddings candidates")
    }
    let scored = context.recent.map { c -> (Conversation, Double) in
      let corpus =
        ([c.title, c.summary] + (context.messages[c.id] ?? []).suffix(10).map(\.content)).joined(
          separator: " ")
      return (c, TextSimilarity.cosine(context.input, corpus))
    }.sorted { $0.1 > $1.1 }
    guard let best = scored.first, best.1 >= 0.18 else {
      return RoutingDecision(decision: .newChat, confidence: 0.78, reason: "No semantic match")
    }
    return RoutingDecision(
      decision: best.0.id == context.current?.id ? .continueCurrent : .switchChat,
      chatID: best.0.id, confidence: min(0.96, 0.55 + best.1),
      reason: "Highest local vector similarity")
  }
}

public struct LLMRouter: ConversationRoutingStrategy {
  public let endpoint: URL
  public let model: String
  public let session: URLSession
  public init(endpoint: URL, model: String, session: URLSession = .shared) {
    self.endpoint = endpoint
    self.model = model
    self.session = session
  }
  public func route(_ context: ConversationContext) async throws -> RoutingDecision {
    let candidates = context.recent.prefix(8).map { c in
      ["id": c.id, "title": c.title, "summary": c.summary]
    }
    let system =
      "You only route conversations. Return JSON with decision (continue_current|switch_chat|new_chat|ask_user), chat_id, confidence (0..1), reason. Never answer the user question."
    let payload: [String: Any] = [
      "model": model, "stream": false, "temperature": 0,
      "messages": [
        ["role": "system", "content": system],
        [
          "role": "user",
          "content":
            "Current id: \(context.current?.id ?? "none")\nCandidates: \(candidates)\nInput: \(context.input)",
        ],
      ],
    ]
    var request = URLRequest(url: completionURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    let (data, response) = try await session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw MiddleAIError.network("Local router unavailable")
    }
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let message =
      ((root?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"]
      as? String ?? ""
    guard let jsonData = extractJSON(message).data(using: .utf8),
      let result = try? JSONDecoder().decode(RoutingDecision.self, from: jsonData)
    else { throw MiddleAIError.invalidResponse("Local router returned invalid JSON") }
    return result
  }
  private var completionURL: URL {
    LocalLLMEndpoint.completionsURL(from: endpoint)
  }
  private func extractJSON(_ text: String) -> String {
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
      return text
    }
    return String(text[start...end])
  }
}

public enum LocalLLMEndpoint {
  public static func completionsURL(from endpoint: URL) -> URL {
    normalized(endpoint, suffix: "chat/completions")
  }

  public static func modelsURL(from endpoint: URL) -> URL {
    normalized(endpoint, suffix: "models")
  }

  private static func normalized(_ endpoint: URL, suffix: String) -> URL {
    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
    components?.query = nil
    components?.fragment = nil
    var parts = (components?.path ?? "").split(separator: "/").map(String.init)
    if let v1 = parts.firstIndex(of: "v1") {
      parts = Array(parts.prefix(through: v1))
    } else {
      parts.append("v1")
    }
    parts.append(contentsOf: suffix.split(separator: "/").map(String.init))
    components?.path = "/" + parts.joined(separator: "/")
    return components?.url ?? endpoint
  }
}

public struct AppleIntelligenceRouter: ConversationRoutingStrategy {
  public init() {}

  public func route(_ context: ConversationContext) async throws -> RoutingDecision {
    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) {
        let model = SystemLanguageModel(
          useCase: .general, guardrails: .permissiveContentTransformations)
        guard model.availability == .available else {
          throw MiddleAIError.configuration("Apple Intelligence ist auf diesem Mac nicht bereit.")
        }
        let candidates = context.recent.prefix(8).map {
          "id=\($0.id); titel=\($0.title); kurzfassung=\($0.summary)"
        }.joined(separator: "\n")
        let session = LanguageModelSession(
          model: model,
          instructions: """
            Du ordnest ausschließlich Unterhaltungen zu und beantwortest niemals die Nutzerfrage. Antworte nur mit einem JSON-Objekt mit decision, chat_id, confidence und reason. decision ist continue_current, switch_chat, new_chat oder ask_user. confidence liegt zwischen 0 und 1.
            """)
        let result = try await session.respond(
          to: """
            Aktueller Chat: \(context.current?.id ?? "keiner")
            Kandidaten:
            \(candidates)
            Neue Eingabe: \(context.input)
            """)
        let text = result.content
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
          let data = String(text[start...end]).data(using: .utf8),
          let decision = try? JSONDecoder().decode(RoutingDecision.self, from: data)
        else {
          throw MiddleAIError.invalidResponse(
            "Apple Intelligence lieferte keine gültige Chat-Auswahl.")
        }
        return decision
      }
    #endif
    throw MiddleAIError.configuration(
      "Apple Intelligence benötigt macOS 26 und ein unterstütztes Gerät.")
  }
}

public struct HybridRouter: ConversationRoutingStrategy {
  public let heuristic: any ConversationRoutingStrategy
  public let embedding: any ConversationRoutingStrategy
  public let llm: (any ConversationRoutingStrategy)?
  public init(
    heuristic: any ConversationRoutingStrategy,
    embedding: any ConversationRoutingStrategy = EmbeddingRouter(),
    llm: (any ConversationRoutingStrategy)? = nil
  ) {
    self.heuristic = heuristic
    self.embedding = embedding
    self.llm = llm
  }
  public func route(_ context: ConversationContext) async throws -> RoutingDecision {
    async let h = heuristic.route(context)
    async let e = embedding.route(context)
    let heuristicResult = try await h
    let embeddingResult = try await e
    if heuristicResult.decision == embeddingResult.decision
      && heuristicResult.chatID == embeddingResult.chatID
    {
      return RoutingDecision(
        decision: heuristicResult.decision, chatID: heuristicResult.chatID,
        confidence: min(0.99, (heuristicResult.confidence + embeddingResult.confidence) / 2 + 0.08),
        reason: "Heuristic and local semantic routers agree")
    }
    // A lexical embedding cannot resolve short references such as "Warum ist das so?".
    // Preserve an actively continued conversation. The configured continuation window is a
    // deliberate user preference and must not be overruled by missing lexical overlap.
    if heuristicResult.decision == .continueCurrent,
      embeddingResult.decision == .newChat,
      heuristicResult.confidence >= 0.75
    {
      return heuristicResult
    }
    if let llm, let result = try? await llm.route(context) { return result }
    return heuristicResult.confidence >= embeddingResult.confidence
      ? heuristicResult : embeddingResult
  }
}
