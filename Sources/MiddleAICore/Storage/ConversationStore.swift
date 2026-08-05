import CSQLite
import Foundation

public protocol ConversationStoreProtocol: Sendable {
  func saveConversation(_ conversation: Conversation) throws
  func conversation(id: String) throws -> Conversation?
  func recentConversations(limit: Int) throws -> [Conversation]
  func saveMessage(_ message: Message, conversationID: String) throws
  func saveExchange(
    user: Message, assistant: Message, conversation: Conversation
  ) throws
  func messages(conversationID: String, limit: Int) throws -> [Message]
  func setSetting(key: String, value: String) throws
  func removeSetting(key: String) throws
  func setting(key: String) throws -> String?
  func deleteAllConversations() throws
  func deleteConversations(lastUsedBefore date: Date) throws
  func deleteEmptyConversations() throws
  func cacheStatistics() throws -> ConversationCacheStatistics
}

public struct ConversationCacheStatistics: Equatable, Sendable {
  public let conversations: Int
  public let messages: Int

  public init(conversations: Int, messages: Int) {
    self.conversations = conversations
    self.messages = messages
  }
}

public final class SQLiteConversationStore: ConversationStoreProtocol, @unchecked Sendable {
  private var db: OpaquePointer?
  private let lock = NSRecursiveLock()

  public init(path: String) throws {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
    let directoryExisted = FileManager.default.fileExists(atPath: directory.path)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    if !directoryExisted
      || directory.standardizedFileURL.path.hasPrefix(ConfigLoader.defaultDirectory.path + "/")
    {
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: directory.path)
    }
    guard sqlite3_open(path, &db) == SQLITE_OK else {
      throw MiddleAIError.storage("Cannot open SQLite database")
    }
    try execute("PRAGMA journal_mode=WAL;")
    try execute("PRAGMA foreign_keys=ON;")
    try execute("PRAGMA secure_delete=FAST;")
    try migrate()
    for databasePath in [path, path + "-wal", path + "-shm"]
    where FileManager.default.fileExists(atPath: databasePath) {
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: databasePath)
    }
  }

  deinit { sqlite3_close(db) }

  private func migrate() throws {
    try execute(
      """
      CREATE TABLE IF NOT EXISTS conversations(
        id TEXT PRIMARY KEY, openwebui_chat_id TEXT, openwebui_base_url TEXT,
        title TEXT NOT NULL, summary TEXT NOT NULL DEFAULT '',
        profile TEXT NOT NULL DEFAULT 'default', created_at REAL NOT NULL, last_used_at REAL NOT NULL
      );
      CREATE INDEX IF NOT EXISTS conversations_last_used ON conversations(last_used_at DESC);
      CREATE TABLE IF NOT EXISTS messages_cache(
        id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        role TEXT NOT NULL, content TEXT NOT NULL, timestamp REAL NOT NULL
      );
      CREATE INDEX IF NOT EXISTS messages_conversation ON messages_cache(conversation_id, timestamp);
      CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS embeddings(conversation_id TEXT PRIMARY KEY, model TEXT, vector BLOB, updated_at REAL);
      """)
    if try !columnExists("openwebui_base_url", in: "conversations") {
      try execute("ALTER TABLE conversations ADD COLUMN openwebui_base_url TEXT;")
    }
  }

  private func columnExists(_ name: String, in table: String) throws -> Bool {
    try withStatement("PRAGMA table_info(\(table))") { statement in
      while sqlite3_step(statement) == SQLITE_ROW {
        if text(1, statement) == name { return true }
      }
      return false
    }
  }

  private func execute(_ sql: String) throws {
    lock.lock()
    defer { lock.unlock() }
    var error: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
      let message = error.map { String(cString: $0) } ?? "Unknown SQLite error"
      sqlite3_free(error)
      throw MiddleAIError.storage(message)
    }
  }

  public func saveConversation(_ c: Conversation) throws {
    try withStatement(
      """
      INSERT INTO conversations(id,openwebui_chat_id,openwebui_base_url,title,summary,profile,created_at,last_used_at)
      VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
      openwebui_chat_id=excluded.openwebui_chat_id,
      openwebui_base_url=excluded.openwebui_base_url,title=excluded.title,
      summary=excluded.summary,profile=excluded.profile,last_used_at=excluded.last_used_at
      """
    ) { statement in
      bind(c.id, 1, statement)
      bind(c.openWebUIChatID, 2, statement)
      bind(c.openWebUIBaseURL, 3, statement)
      bind(c.title, 4, statement)
      bind(c.summary, 5, statement)
      bind(c.profile, 6, statement)
      sqlite3_bind_double(statement, 7, c.createdAt.timeIntervalSince1970)
      sqlite3_bind_double(statement, 8, c.lastUsedAt.timeIntervalSince1970)
      try stepDone(statement)
    }
  }

  public func conversation(id: String) throws -> Conversation? {
    try withStatement(
      "SELECT id,openwebui_chat_id,openwebui_base_url,title,summary,profile,created_at,last_used_at FROM conversations WHERE id=?"
    ) { s in
      bind(id, 1, s)
      guard sqlite3_step(s) == SQLITE_ROW else { return nil }
      return decodeConversation(s)
    }
  }

  public func recentConversations(limit: Int = 20) throws -> [Conversation] {
    try withStatement(
      "SELECT id,openwebui_chat_id,openwebui_base_url,title,summary,profile,created_at,last_used_at FROM conversations ORDER BY last_used_at DESC LIMIT ?"
    ) { s in
      sqlite3_bind_int(s, 1, Int32(limit))
      var result: [Conversation] = []
      while sqlite3_step(s) == SQLITE_ROW { result.append(decodeConversation(s)) }
      return result
    }
  }

  public func saveMessage(_ m: Message, conversationID: String) throws {
    try withStatement(
      "INSERT OR REPLACE INTO messages_cache(id,conversation_id,role,content,timestamp) VALUES(?,?,?,?,?)"
    ) { s in
      bind(m.id, 1, s)
      bind(conversationID, 2, s)
      bind(m.role.rawValue, 3, s)
      bind(m.content, 4, s)
      sqlite3_bind_double(s, 5, m.timestamp.timeIntervalSince1970)
      try stepDone(s)
    }
  }

  public func saveExchange(
    user: Message, assistant: Message, conversation: Conversation
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    try execute("BEGIN IMMEDIATE;")
    do {
      try saveConversation(conversation)
      try saveMessage(user, conversationID: conversation.id)
      try saveMessage(assistant, conversationID: conversation.id)
      try setSetting(key: "current_conversation_id", value: conversation.id)
      try execute("COMMIT;")
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  public func messages(conversationID: String, limit: Int = 30) throws -> [Message] {
    try withStatement(
      "SELECT id,role,content,timestamp FROM (SELECT rowid AS insertion_order,* FROM messages_cache WHERE conversation_id=? ORDER BY timestamp DESC,insertion_order DESC LIMIT ?) ORDER BY timestamp,insertion_order"
    ) { s in
      bind(conversationID, 1, s)
      sqlite3_bind_int(s, 2, Int32(limit))
      var result: [Message] = []
      while sqlite3_step(s) == SQLITE_ROW {
        result.append(
          Message(
            id: text(0, s), role: MessageRole(rawValue: text(1, s)) ?? .user, content: text(2, s),
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(s, 3))))
      }
      return result
    }
  }

  public func setSetting(key: String, value: String) throws {
    try withStatement(
      "INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value"
    ) { s in
      bind(key, 1, s)
      bind(value, 2, s)
      try stepDone(s)
    }
  }
  public func setting(key: String) throws -> String? {
    try withStatement("SELECT value FROM settings WHERE key=?") { s in
      bind(key, 1, s)
      return sqlite3_step(s) == SQLITE_ROW ? text(0, s) : nil
    }
  }

  public func removeSetting(key: String) throws {
    try withStatement("DELETE FROM settings WHERE key=?") { statement in
      bind(key, 1, statement)
      try stepDone(statement)
    }
  }

  public func deleteAllConversations() throws {
    try execute("BEGIN IMMEDIATE;")
    do {
      try execute("DELETE FROM conversations;")
      try execute("DELETE FROM settings WHERE key='current_conversation_id';")
      try execute("COMMIT;")
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  public func deleteConversations(lastUsedBefore date: Date) throws {
    try withStatement("DELETE FROM conversations WHERE last_used_at < ?") { statement in
      sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
      try stepDone(statement)
    }
    if let current = try setting(key: "current_conversation_id"),
      try conversation(id: current) == nil
    {
      try execute("DELETE FROM settings WHERE key='current_conversation_id';")
    }
  }

  public func deleteEmptyConversations() throws {
    try execute("BEGIN IMMEDIATE;")
    do {
      try execute(
        "DELETE FROM embeddings WHERE conversation_id IN (SELECT id FROM conversations WHERE NOT EXISTS (SELECT 1 FROM messages_cache WHERE conversation_id=conversations.id));"
      )
      try execute(
        "DELETE FROM conversations WHERE NOT EXISTS (SELECT 1 FROM messages_cache WHERE conversation_id=conversations.id);"
      )
      try execute(
        "DELETE FROM settings WHERE key='current_conversation_id' AND NOT EXISTS (SELECT 1 FROM conversations WHERE id=settings.value);"
      )
      try execute("COMMIT;")
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  public func cacheStatistics() throws -> ConversationCacheStatistics {
    let conversations = try scalarCount("SELECT COUNT(*) FROM conversations")
    let messages = try scalarCount("SELECT COUNT(*) FROM messages_cache")
    return ConversationCacheStatistics(conversations: conversations, messages: messages)
  }

  private func scalarCount(_ sql: String) throws -> Int {
    try withStatement(sql) { statement in
      guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
      return Int(sqlite3_column_int64(statement, 0))
    }
  }

  private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw MiddleAIError.storage(errorMessage)
    }
    defer { sqlite3_finalize(statement) }
    return try body(statement)
  }
  private var errorMessage: String {
    db.flatMap(sqlite3_errmsg).map(String.init(cString:)) ?? "Unknown SQLite error"
  }
  private func stepDone(_ s: OpaquePointer) throws {
    guard sqlite3_step(s) == SQLITE_DONE else { throw MiddleAIError.storage(errorMessage) }
  }
  private func bind(_ value: String?, _ index: Int32, _ s: OpaquePointer) {
    if let value {
      sqlite3_bind_text(s, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    } else {
      sqlite3_bind_null(s, index)
    }
  }
  private func text(_ index: Int32, _ s: OpaquePointer) -> String {
    sqlite3_column_text(s, index).map { String(cString: $0) } ?? ""
  }
  private func decodeConversation(_ s: OpaquePointer) -> Conversation {
    Conversation(
      id: text(0, s), openWebUIChatID: sqlite3_column_type(s, 1) == SQLITE_NULL ? nil : text(1, s),
      openWebUIBaseURL: sqlite3_column_type(s, 2) == SQLITE_NULL ? nil : text(2, s),
      title: text(3, s), summary: text(4, s), profile: text(5, s),
      createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 6)),
      lastUsedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 7)))
  }
}

public final class InMemoryConversationStore: ConversationStoreProtocol, @unchecked Sendable {
  private var conversations: [String: Conversation] = [:]
  private var cached: [String: [Message]] = [:]
  private var settings: [String: String] = [:]
  private let lock = NSLock()
  public init() {}
  public func saveConversation(_ c: Conversation) throws {
    lock.withLock { conversations[c.id] = c }
  }
  public func conversation(id: String) throws -> Conversation? {
    lock.withLock { conversations[id] }
  }
  public func recentConversations(limit: Int) throws -> [Conversation] {
    lock.withLock {
      Array(conversations.values.sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(limit))
    }
  }
  public func saveMessage(_ m: Message, conversationID: String) throws {
    lock.withLock { cached[conversationID, default: []].append(m) }
  }
  public func saveExchange(
    user: Message, assistant: Message, conversation: Conversation
  ) throws {
    lock.withLock {
      conversations[conversation.id] = conversation
      cached[conversation.id, default: []].append(contentsOf: [user, assistant])
      settings["current_conversation_id"] = conversation.id
    }
  }
  public func messages(conversationID: String, limit: Int) throws -> [Message] {
    lock.withLock { Array(cached[conversationID, default: []].suffix(limit)) }
  }
  public func setSetting(key: String, value: String) throws {
    lock.withLock { settings[key] = value }
  }
  public func removeSetting(key: String) throws { lock.withLock { settings[key] = nil } }
  public func setting(key: String) throws -> String? { lock.withLock { settings[key] } }
  public func deleteAllConversations() throws {
    lock.withLock {
      conversations.removeAll()
      cached.removeAll()
      settings["current_conversation_id"] = nil
    }
  }
  public func deleteConversations(lastUsedBefore date: Date) throws {
    lock.withLock {
      let removed = Set(
        conversations.values.filter { $0.lastUsedAt < date }.map(\.id))
      for id in removed {
        conversations[id] = nil
        cached[id] = nil
      }
      if let active = settings["current_conversation_id"], removed.contains(active) {
        settings["current_conversation_id"] = nil
      }
    }
  }
  public func deleteEmptyConversations() throws {
    lock.withLock {
      let empty = Set(
        conversations.keys.filter { cached[$0, default: []].isEmpty })
      for id in empty {
        conversations[id] = nil
        cached[id] = nil
      }
      if let active = settings["current_conversation_id"], empty.contains(active) {
        settings["current_conversation_id"] = nil
      }
    }
  }
  public func cacheStatistics() throws -> ConversationCacheStatistics {
    lock.withLock {
      ConversationCacheStatistics(
        conversations: conversations.count,
        messages: cached.values.reduce(0) { $0 + $1.count })
    }
  }
}

extension NSLock {
  fileprivate func withLock<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}
