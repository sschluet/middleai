import CSQLite
import Foundation

/// Persistent local storage for explicitly granted knowledge and profile memories.
/// It intentionally has no API that can discover or ingest files by itself.
public protocol LocalContextStoreProtocol: Sendable {
  func saveKnowledgeSource(_ source: KnowledgeSource) throws
  func knowledgeSource(id: String) throws -> KnowledgeSource?
  func knowledgeSources() throws -> [KnowledgeSource]
  func deleteKnowledgeSource(id: String) throws
  func replaceKnowledgeChunks(
    sourceID: String, chunks: [KnowledgeChunk], indexedAt: Date
  ) throws
  func knowledgeCandidates(tokens: [String], limit: Int) throws -> [StoredKnowledgeChunk]

  func saveProfileMemory(_ memory: ProfileMemory) throws
  func profileMemory(id: String) throws -> ProfileMemory?
  func profileMemories(profile: String, includeExpired: Bool, now: Date) throws
    -> [ProfileMemory]
  func deleteProfileMemory(id: String) throws
  @discardableResult func deleteExpiredProfileMemories(now: Date) throws -> Int
}

public final class SQLiteLocalContextStore: LocalContextStoreProtocol, @unchecked Sendable {
  private var db: OpaquePointer?
  private let lock = NSRecursiveLock()

  public init(path: String) throws {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    guard sqlite3_open(path, &db) == SQLITE_OK else {
      throw MiddleAIError.storage("Lokaler Kontextspeicher konnte nicht geöffnet werden")
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
      CREATE TABLE IF NOT EXISTS knowledge_sources(
        id TEXT PRIMARY KEY,
        path TEXT NOT NULL UNIQUE,
        display_name TEXT NOT NULL,
        kind TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        created_at REAL NOT NULL,
        last_indexed_at REAL
      );
      CREATE TABLE IF NOT EXISTS knowledge_chunks(
        id TEXT PRIMARY KEY,
        source_id TEXT NOT NULL REFERENCES knowledge_sources(id) ON DELETE CASCADE,
        relative_path TEXT NOT NULL,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        search_terms TEXT NOT NULL,
        start_line INTEGER NOT NULL,
        end_line INTEGER NOT NULL,
        updated_at REAL NOT NULL
      );
      CREATE INDEX IF NOT EXISTS knowledge_chunks_source ON knowledge_chunks(source_id);
      CREATE INDEX IF NOT EXISTS knowledge_sources_enabled ON knowledge_sources(enabled);

      CREATE TABLE IF NOT EXISTS profile_memories(
        id TEXT PRIMARY KEY,
        profile TEXT NOT NULL,
        memory_key TEXT NOT NULL,
        value TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        expires_at REAL,
        UNIQUE(profile, memory_key)
      );
      CREATE INDEX IF NOT EXISTS profile_memories_profile ON profile_memories(profile, updated_at DESC);
      CREATE INDEX IF NOT EXISTS profile_memories_expiry ON profile_memories(expires_at);
      """)
  }

  public func saveKnowledgeSource(_ source: KnowledgeSource) throws {
    try withStatement(
      """
      INSERT INTO knowledge_sources(id,path,display_name,kind,enabled,created_at,last_indexed_at)
      VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
      path=excluded.path,display_name=excluded.display_name,kind=excluded.kind,
      enabled=excluded.enabled,last_indexed_at=excluded.last_indexed_at
      """
    ) { statement in
      bind(source.id, 1, statement)
      bind(source.path, 2, statement)
      bind(source.displayName, 3, statement)
      bind(source.kind.rawValue, 4, statement)
      sqlite3_bind_int(statement, 5, source.enabled ? 1 : 0)
      sqlite3_bind_double(statement, 6, source.createdAt.timeIntervalSince1970)
      bind(source.lastIndexedAt, 7, statement)
      try stepDone(statement)
    }
  }

  public func knowledgeSource(id: String) throws -> KnowledgeSource? {
    try withStatement(
      "SELECT id,path,display_name,kind,enabled,created_at,last_indexed_at FROM knowledge_sources WHERE id=?"
    ) { statement in
      bind(id, 1, statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return decodeKnowledgeSource(statement)
    }
  }

  public func knowledgeSources() throws -> [KnowledgeSource] {
    try withStatement(
      "SELECT id,path,display_name,kind,enabled,created_at,last_indexed_at FROM knowledge_sources ORDER BY display_name COLLATE NOCASE"
    ) { statement in
      var result: [KnowledgeSource] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        result.append(decodeKnowledgeSource(statement))
      }
      return result
    }
  }

  public func deleteKnowledgeSource(id: String) throws {
    try withStatement("DELETE FROM knowledge_sources WHERE id=?") { statement in
      bind(id, 1, statement)
      try stepDone(statement)
    }
  }

  public func replaceKnowledgeChunks(
    sourceID: String, chunks: [KnowledgeChunk], indexedAt: Date
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    try execute("BEGIN IMMEDIATE;")
    do {
      try withStatement("DELETE FROM knowledge_chunks WHERE source_id=?") { statement in
        bind(sourceID, 1, statement)
        try stepDone(statement)
      }
      for chunk in chunks {
        try withStatement(
          """
          INSERT INTO knowledge_chunks(
            id,source_id,relative_path,title,content,search_terms,start_line,end_line,updated_at
          ) VALUES(?,?,?,?,?,?,?,?,?)
          """
        ) { statement in
          bind(chunk.id, 1, statement)
          bind(sourceID, 2, statement)
          bind(chunk.relativePath, 3, statement)
          bind(chunk.title, 4, statement)
          bind(chunk.content, 5, statement)
          bind(chunk.searchTerms, 6, statement)
          sqlite3_bind_int64(statement, 7, sqlite3_int64(chunk.startLine))
          sqlite3_bind_int64(statement, 8, sqlite3_int64(chunk.endLine))
          sqlite3_bind_double(statement, 9, chunk.updatedAt.timeIntervalSince1970)
          try stepDone(statement)
        }
      }
      try withStatement("UPDATE knowledge_sources SET last_indexed_at=? WHERE id=?") { statement in
        sqlite3_bind_double(statement, 1, indexedAt.timeIntervalSince1970)
        bind(sourceID, 2, statement)
        try stepDone(statement)
      }
      try execute("COMMIT;")
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  public func knowledgeCandidates(tokens: [String], limit: Int) throws -> [StoredKnowledgeChunk] {
    let safeLimit = max(1, min(limit, 500))
    let queryTokens = Array(Set(tokens.filter { !$0.isEmpty })).prefix(12)
    var sql =
      """
      SELECT c.id,c.source_id,c.relative_path,c.title,c.content,c.search_terms,
             c.start_line,c.end_line,c.updated_at,
             s.path,s.display_name,s.kind,s.enabled,s.created_at,s.last_indexed_at
      FROM knowledge_chunks c JOIN knowledge_sources s ON s.id=c.source_id
      WHERE s.enabled=1
      """
    if !queryTokens.isEmpty {
      sql +=
        " AND (" + queryTokens.map { _ in "c.search_terms LIKE ?" }.joined(separator: " OR ") + ")"
    }
    sql += " ORDER BY c.updated_at DESC LIMIT ?"
    return try withStatement(sql) { statement in
      var parameter: Int32 = 1
      for token in queryTokens {
        bind("% \(token) %", parameter, statement)
        parameter += 1
      }
      sqlite3_bind_int(statement, parameter, Int32(safeLimit))
      var result: [StoredKnowledgeChunk] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        let chunk = KnowledgeChunk(
          id: text(0, statement), sourceID: text(1, statement),
          relativePath: text(2, statement), title: text(3, statement),
          content: text(4, statement), searchTerms: text(5, statement),
          startLine: Int(sqlite3_column_int64(statement, 6)),
          endLine: Int(sqlite3_column_int64(statement, 7)),
          updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)))
        let source = KnowledgeSource(
          id: chunk.sourceID, path: text(9, statement), displayName: text(10, statement),
          kind: KnowledgeSource.Kind(rawValue: text(11, statement)) ?? .file,
          enabled: sqlite3_column_int(statement, 12) != 0,
          createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 13)),
          lastIndexedAt: date(14, statement))
        result.append(StoredKnowledgeChunk(source: source, chunk: chunk))
      }
      return result
    }
  }

  public func saveProfileMemory(_ memory: ProfileMemory) throws {
    try withStatement(
      """
      INSERT INTO profile_memories(id,profile,memory_key,value,created_at,updated_at,expires_at)
      VALUES(?,?,?,?,?,?,?) ON CONFLICT(profile,memory_key) DO UPDATE SET
      id=excluded.id,value=excluded.value,updated_at=excluded.updated_at,expires_at=excluded.expires_at
      """
    ) { statement in
      bind(memory.id, 1, statement)
      bind(memory.profile, 2, statement)
      bind(memory.key, 3, statement)
      bind(memory.value, 4, statement)
      sqlite3_bind_double(statement, 5, memory.createdAt.timeIntervalSince1970)
      sqlite3_bind_double(statement, 6, memory.updatedAt.timeIntervalSince1970)
      bind(memory.expiresAt, 7, statement)
      try stepDone(statement)
    }
  }

  public func profileMemory(id: String) throws -> ProfileMemory? {
    try withStatement(
      "SELECT id,profile,memory_key,value,created_at,updated_at,expires_at FROM profile_memories WHERE id=?"
    ) { statement in
      bind(id, 1, statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return decodeProfileMemory(statement)
    }
  }

  public func profileMemories(
    profile: String, includeExpired: Bool = false, now: Date = Date()
  ) throws -> [ProfileMemory] {
    let predicate = includeExpired ? "" : " AND (expires_at IS NULL OR expires_at>?)"
    return try withStatement(
      "SELECT id,profile,memory_key,value,created_at,updated_at,expires_at FROM profile_memories WHERE profile=?\(predicate) ORDER BY updated_at DESC"
    ) { statement in
      bind(profile, 1, statement)
      if !includeExpired { sqlite3_bind_double(statement, 2, now.timeIntervalSince1970) }
      var result: [ProfileMemory] = []
      while sqlite3_step(statement) == SQLITE_ROW { result.append(decodeProfileMemory(statement)) }
      return result
    }
  }

  public func deleteProfileMemory(id: String) throws {
    try withStatement("DELETE FROM profile_memories WHERE id=?") { statement in
      bind(id, 1, statement)
      try stepDone(statement)
    }
  }

  @discardableResult public func deleteExpiredProfileMemories(now: Date = Date()) throws -> Int {
    try withStatement("DELETE FROM profile_memories WHERE expires_at IS NOT NULL AND expires_at<=?")
    {
      statement in
      sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
      try stepDone(statement)
      return Int(sqlite3_changes(db))
    }
  }

  private func execute(_ sql: String) throws {
    lock.lock()
    defer { lock.unlock() }
    var error: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
      let message = error.map { String(cString: $0) } ?? "Unbekannter SQLite-Fehler"
      sqlite3_free(error)
      throw MiddleAIError.storage(message)
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
    db.flatMap(sqlite3_errmsg).map(String.init(cString:)) ?? "Unbekannter SQLite-Fehler"
  }

  private func stepDone(_ statement: OpaquePointer) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw MiddleAIError.storage(errorMessage)
    }
  }

  private func bind(_ value: String?, _ index: Int32, _ statement: OpaquePointer) {
    if let value {
      sqlite3_bind_text(
        statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    } else {
      sqlite3_bind_null(statement, index)
    }
  }

  private func bind(_ value: Date?, _ index: Int32, _ statement: OpaquePointer) {
    if let value {
      sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
    } else {
      sqlite3_bind_null(statement, index)
    }
  }

  private func text(_ index: Int32, _ statement: OpaquePointer) -> String {
    sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
  }

  private func date(_ index: Int32, _ statement: OpaquePointer) -> Date? {
    sqlite3_column_type(statement, index) == SQLITE_NULL
      ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
  }

  private func decodeKnowledgeSource(_ statement: OpaquePointer) -> KnowledgeSource {
    KnowledgeSource(
      id: text(0, statement), path: text(1, statement), displayName: text(2, statement),
      kind: KnowledgeSource.Kind(rawValue: text(3, statement)) ?? .file,
      enabled: sqlite3_column_int(statement, 4) != 0,
      createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
      lastIndexedAt: date(6, statement))
  }

  private func decodeProfileMemory(_ statement: OpaquePointer) -> ProfileMemory {
    ProfileMemory(
      id: text(0, statement), profile: text(1, statement), key: text(2, statement),
      value: text(3, statement),
      createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
      updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
      expiresAt: date(6, statement))
  }
}
