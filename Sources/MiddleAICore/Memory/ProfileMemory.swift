import Foundation

public struct ProfileMemory: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var profile: String
  public var key: String
  public var value: String
  public var createdAt: Date
  public var updatedAt: Date
  public var expiresAt: Date?

  public init(
    id: String = UUID().uuidString, profile: String, key: String, value: String,
    createdAt: Date = Date(), updatedAt: Date = Date(), expiresAt: Date? = nil
  ) {
    self.id = id
    self.profile = profile
    self.key = key
    self.value = value
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.expiresAt = expiresAt
  }

  public func isExpired(at date: Date = Date()) -> Bool {
    expiresAt.map { $0 <= date } ?? false
  }
}

/// CRUD service for memories that the user explicitly creates. The service never observes
/// conversations and deliberately exposes no automatic learning API.
public actor ProfileMemoryService {
  private let store: any LocalContextStoreProtocol
  private let maximumKeyLength: Int
  private let maximumValueLength: Int

  public init(
    store: any LocalContextStoreProtocol, maximumKeyLength: Int = 120,
    maximumValueLength: Int = 4_000
  ) {
    self.store = store
    self.maximumKeyLength = maximumKeyLength
    self.maximumValueLength = maximumValueLength
  }

  @discardableResult public func create(
    profile: String, key: String, value: String, expiresAt: Date? = nil,
    now: Date = Date()
  ) throws -> ProfileMemory {
    let validated = try validate(profile: profile, key: key, value: value, expiresAt: expiresAt)
    let memory = ProfileMemory(
      profile: validated.profile, key: validated.key, value: validated.value,
      createdAt: now, updatedAt: now, expiresAt: expiresAt)
    try store.saveProfileMemory(memory)
    return memory
  }

  @discardableResult public func update(
    id: String, key: String, value: String, expiresAt: Date?, now: Date = Date()
  ) throws -> ProfileMemory {
    guard var memory = try store.profileMemory(id: id) else {
      throw MiddleAIError.storage("Die lokale Erinnerung wurde nicht gefunden")
    }
    let validated = try validate(
      profile: memory.profile, key: key, value: value, expiresAt: expiresAt)
    memory.key = validated.key
    memory.value = validated.value
    memory.updatedAt = now
    memory.expiresAt = expiresAt
    try store.saveProfileMemory(memory)
    return memory
  }

  public func memory(id: String, now: Date = Date()) throws -> ProfileMemory? {
    guard let memory = try store.profileMemory(id: id), !memory.isExpired(at: now) else {
      return nil
    }
    return memory
  }

  public func memories(
    profile: String, includeExpired: Bool = false, now: Date = Date()
  ) throws -> [ProfileMemory] {
    let profile = try validatedProfile(profile)
    return try store.profileMemories(
      profile: profile, includeExpired: includeExpired, now: now)
  }

  public func delete(id: String) throws {
    try store.deleteProfileMemory(id: id)
  }

  @discardableResult public func purgeExpired(now: Date = Date()) throws -> Int {
    try store.deleteExpiredProfileMemories(now: now)
  }

  /// Returns a small prompt context scoped to one profile. Retrieval is local and lexical.
  /// An empty query returns the most recently updated entries.
  public func context(
    profile: String, matching query: String = "", maximumCharacters: Int = 3_000,
    now: Date = Date()
  ) throws -> String {
    let memories = try memories(profile: profile, now: now)
    let queryTokens = Set(TextSimilarity.tokens(query))
    let scored: [(memory: ProfileMemory, score: Double)] = memories.map { memory in
      let memoryTokens = Set(TextSimilarity.tokens(memory.key + " " + memory.value))
      let matchingCount = queryTokens.intersection(memoryTokens).count
      let overlap: Double
      if queryTokens.isEmpty {
        overlap = 1
      } else {
        overlap = Double(matchingCount) / Double(queryTokens.count)
      }
      return (memory: memory, score: overlap)
    }
    let ranked = scored.filter { queryTokens.isEmpty || $0.score > 0 }
      .sorted { lhs, rhs in
        lhs.score == rhs.score
          ? lhs.memory.updatedAt > rhs.memory.updatedAt : lhs.score > rhs.score
      }

    let budget = max(0, maximumCharacters)
    var result = ""
    for item in ranked {
      let memory = item.memory
      let line = "- \(memory.key): \(memory.value)\n"
      guard result.count + line.count <= budget else { break }
      result += line
    }
    guard !result.isEmpty else { return "" }
    return "Vom Nutzer explizit gespeicherte Hinweise für dieses Profil:\n" + result
  }

  private func validate(
    profile: String, key: String, value: String, expiresAt: Date?
  ) throws -> (profile: String, key: String, value: String) {
    let profile = try validatedProfile(profile)
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, key.count <= maximumKeyLength else {
      throw MiddleAIError.configuration("Der Erinnerungstitel ist leer oder zu lang")
    }
    guard !value.isEmpty, value.count <= maximumValueLength else {
      throw MiddleAIError.configuration("Der Erinnerungsinhalt ist leer oder zu lang")
    }
    if let expiresAt, !expiresAt.timeIntervalSince1970.isFinite {
      throw MiddleAIError.configuration("Das Ablaufdatum ist ungültig")
    }
    return (profile, key, value)
  }

  private func validatedProfile(_ profile: String) throws -> String {
    let profile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !profile.isEmpty, profile.count <= 100,
      profile.unicodeScalars.allSatisfy({
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.")).contains($0)
      })
    else { throw MiddleAIError.configuration("Die Profil-ID ist ungültig") }
    return profile
  }
}
