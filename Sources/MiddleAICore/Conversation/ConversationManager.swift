import Foundation

public final class ConversationManager: @unchecked Sendable {
  private let store: any ConversationStoreProtocol
  private let router: any ConversationRoutingStrategy
  private let confidenceAsk: Double
  private let lock = NSLock()
  private var currentID: String?

  public init(
    store: any ConversationStoreProtocol, router: any ConversationRoutingStrategy,
    confidenceAsk: Double = 0.55
  ) {
    self.store = store
    self.router = router
    self.confidenceAsk = confidenceAsk
    self.currentID = try? store.setting(key: "current_conversation_id")
  }

  public var currentConversation: Conversation? {
    lock.managerLock { currentID }.flatMap { try? store.conversation(id: $0) }
  }

  public func select(for input: String) async throws -> (Conversation?, RoutingDecision) {
    let recent = try store.recentConversations(limit: 20)
    var messages: [String: [Message]] = [:]
    for c in recent { messages[c.id] = try store.messages(conversationID: c.id, limit: 16) }
    let decision = try await router.route(
      ConversationContext(
        input: input, current: currentConversation, recent: recent, messages: messages))
    if decision.confidence < confidenceAsk {
      return (
        currentConversation,
        RoutingDecision(
          decision: .askUser, chatID: currentConversation?.id, confidence: decision.confidence,
          reason: "Routing confidence below configured threshold")
      )
    }
    switch decision.decision {
    case .continueCurrent: return (currentConversation, decision)
    case .switchChat:
      guard let id = decision.chatID, let c = try store.conversation(id: id) else {
        return (
          nil,
          RoutingDecision(
            decision: .newChat, confidence: 0.8, reason: "Selected chat no longer exists")
        )
      }
      try activate(c.id)
      return (c, decision)
    case .newChat: return (nil, decision)
    case .askUser: return (currentConversation, decision)
    }
  }

  public func create(title: String, profile: String) throws -> Conversation {
    let c = Conversation(title: title, summary: String(title.prefix(240)), profile: profile)
    try store.saveConversation(c)
    try activate(c.id)
    return c
  }
  public func update(_ c: Conversation) throws {
    try store.saveConversation(c)
    try activate(c.id)
  }
  public func add(_ message: Message, to conversationID: String) throws {
    try store.saveMessage(message, conversationID: conversationID)
  }
  public func saveExchange(
    user: Message, assistant: Message, conversation: Conversation
  ) throws {
    try store.saveExchange(user: user, assistant: assistant, conversation: conversation)
    lock.managerLock { currentID = conversation.id }
  }
  public func messages(for id: String) throws -> [Message] {
    try store.messages(conversationID: id, limit: 100)
  }
  public func previous() throws -> Conversation? {
    let recent = try store.recentConversations(limit: 3)
    guard let candidate = recent.first(where: { $0.id != currentConversation?.id }) else {
      return nil
    }
    try activate(candidate.id)
    return candidate
  }
  public func switchToTopic(_ topic: String) throws -> Conversation? {
    let best = try store.recentConversations(limit: 30).map {
      ($0, TextSimilarity.cosine(topic, $0.title + " " + $0.summary))
    }.max { $0.1 < $1.1 }
    guard let best, best.1 > 0 else { return nil }
    try activate(best.0.id)
    return best.0
  }
  public func list() throws -> [Conversation] { try store.recentConversations(limit: 50) }
  public func cacheStatistics() throws -> ConversationCacheStatistics {
    try store.cacheStatistics()
  }
  public func clearLocalHistory() throws {
    try store.deleteAllConversations()
    lock.managerLock { currentID = nil }
  }
  public func purgeLocalHistory(olderThan date: Date) throws {
    try store.deleteConversations(lastUsedBefore: date)
    if let active = lock.managerLock({ currentID }), try store.conversation(id: active) == nil {
      lock.managerLock { currentID = nil }
    }
  }
  public func activate(_ id: String) throws {
    guard try store.conversation(id: id) != nil else {
      throw MiddleAIError.storage("Conversation no longer exists")
    }
    lock.managerLock { currentID = id }
    try store.setSetting(key: "current_conversation_id", value: id)
  }
}

extension NSLock {
  fileprivate func managerLock<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}
