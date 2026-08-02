import Foundation

public enum MessageRole: String, Codable, Sendable { case system, user, assistant }

public struct Message: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var role: MessageRole
  public var content: String
  public var timestamp: Date

  public init(
    id: String = UUID().uuidString, role: MessageRole, content: String, timestamp: Date = Date()
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.timestamp = timestamp
  }
}

public struct Conversation: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var openWebUIChatID: String?
  public var openWebUIBaseURL: String?
  public var title: String
  public var summary: String
  public var profile: String
  public var createdAt: Date
  public var lastUsedAt: Date

  public init(
    id: String = UUID().uuidString, openWebUIChatID: String? = nil,
    openWebUIBaseURL: String? = nil, title: String,
    summary: String = "", profile: String = "default", createdAt: Date = Date(),
    lastUsedAt: Date = Date()
  ) {
    self.id = id
    self.openWebUIChatID = openWebUIChatID
    self.openWebUIBaseURL = openWebUIBaseURL
    self.title = title
    self.summary = summary
    self.profile = profile
    self.createdAt = createdAt
    self.lastUsedAt = lastUsedAt
  }
}

public enum RoutingDecisionKind: String, Codable, Sendable {
  case continueCurrent = "continue_current"
  case switchChat = "switch_chat"
  case newChat = "new_chat"
  case askUser = "ask_user"
}

public struct RoutingDecision: Codable, Equatable, Sendable {
  public var decision: RoutingDecisionKind
  public var chatID: String?
  public var confidence: Double
  public var reason: String

  enum CodingKeys: String, CodingKey {
    case decision
    case chatID = "chat_id"
    case confidence
    case reason
  }

  public init(
    decision: RoutingDecisionKind, chatID: String? = nil, confidence: Double, reason: String
  ) {
    self.decision = decision
    self.chatID = chatID
    self.confidence = confidence
    self.reason = reason
  }
}

public struct ConversationContext: Sendable {
  public var input: String
  public var current: Conversation?
  public var recent: [Conversation]
  public var messages: [String: [Message]]
  public var now: Date

  public init(
    input: String, current: Conversation?, recent: [Conversation], messages: [String: [Message]],
    now: Date = Date()
  ) {
    self.input = input
    self.current = current
    self.recent = recent
    self.messages = messages
    self.now = now
  }
}

public struct Profile: Codable, Equatable, Sendable {
  public var name: String
  public var model: String
  public var systemPrompt: String?
  public var temperature: Double?
  public var ttsVoice: String?
  public var knowledgeCollection: String?

  public init(
    name: String, model: String = "", systemPrompt: String? = nil, temperature: Double? = nil,
    ttsVoice: String? = nil, knowledgeCollection: String? = nil
  ) {
    self.name = name
    self.model = model
    self.systemPrompt = systemPrompt
    self.temperature = temperature
    self.ttsVoice = ttsVoice
    self.knowledgeCollection = knowledgeCollection
  }
}

public enum MiddleAIError: LocalizedError, Equatable {
  case configuration(String)
  case storage(String)
  case authentication
  case network(String)
  case invalidResponse(String)
  case noModel
  public var errorDescription: String? {
    switch self {
    case .configuration(let s): return "Konfigurationsfehler: \(s)"
    case .storage(let s): return "Speicherfehler: \(s)"
    case .authentication:
      return "Die Anmeldung bei OpenWebUI ist fehlgeschlagen. Bitte Benutzername und Passwort prüfen."
    case .network(let s): return "OpenWebUI-Fehler: \(s)"
    case .invalidResponse(let s): return "OpenWebUI hat eine unerwartete Antwort geliefert: \(s)"
    case .noModel: return "Es ist keine OpenWebUI-Modell-ID eingestellt."
    }
  }
}
