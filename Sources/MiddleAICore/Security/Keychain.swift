import CryptoKit
import Foundation
import Security

public protocol CredentialStore: Sendable {
  func save(_ value: String, account: String) throws
  func read(account: String) throws -> String?
  func delete(account: String) throws
}

public struct KeychainCredentialStore: CredentialStore, Sendable {
  public let service: String
  public init(service: String = "de.middleai.openwebui") { self.service = service }
  public func save(_ value: String, account: String) throws {
    let match: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let attributes: [String: Any] = [
      kSecValueData as String: Data(value.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    var status = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var item = match
      for (key, value) in attributes { item[key] = value }
      status = SecItemAdd(item as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
      throw MiddleAIError.configuration("Keychain write failed (\(status))")
    }
  }
  public func read(account: String) throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account, kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw MiddleAIError.configuration("Keychain read failed (\(status))")
    }
    // Upgrade legacy AfterFirstUnlock items in place. Authentication must not fail merely because
    // an older macOS version refuses this optional hardening update.
    let match: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let attributes: [String: Any] = [
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ]
    _ = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
    return String(data: data, encoding: .utf8)
  }
  public func delete(account: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw MiddleAIError.configuration("Keychain delete failed (\(status))")
    }
  }
}

/// Separates OpenWebUI credentials by server and MiddleAI profile. Legacy unscoped accounts are
/// migrated lazily, then deleted. A credential newly written by an older UI is treated as an
/// intentional update and migrated on the next read.
public struct ScopedCredentialStore: CredentialStore, Sendable {
  private let base: any CredentialStore
  public let scopeIdentifier: String

  public init(base: any CredentialStore, baseURL: String, profile: String) {
    self.base = base
    let normalizedURL: String
    if var components = URLComponents(string: baseURL) {
      components.scheme = components.scheme?.lowercased()
      components.host = components.host?.lowercased()
      components.query = nil
      components.fragment = nil
      while components.path.hasSuffix("/") { components.path.removeLast() }
      normalizedURL = components.string ?? baseURL
    } else {
      normalizedURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    let material = Data("\(normalizedURL)|\(profile.lowercased())".utf8)
    self.scopeIdentifier = SHA256.hash(data: material).prefix(12)
      .map { String(format: "%02x", $0) }.joined()
  }

  public func save(_ value: String, account: String) throws {
    try base.save(value, account: scoped(account))
  }

  public func read(account: String) throws -> String? {
    // The legacy account wins only while it exists. It is immediately moved to the scoped name.
    if let legacy = try base.read(account: account) {
      try base.save(legacy, account: scoped(account))
      try base.delete(account: account)
      return legacy
    }
    return try base.read(account: scoped(account))
  }

  public func delete(account: String) throws {
    try base.delete(account: scoped(account))
    try base.delete(account: account)
  }

  public func scopedAccount(for account: String) -> String { scoped(account) }

  private func scoped(_ account: String) -> String {
    "openwebui.\(scopeIdentifier).\(account)"
  }
}

public struct EnvironmentCredentialStore: CredentialStore, Sendable {
  public init() {}
  public func save(_ value: String, account: String) throws {
    throw MiddleAIError.configuration("Environment credentials are read-only")
  }
  public func read(account: String) throws -> String? {
    ProcessInfo.processInfo.environment[
      account == "password" ? "MIDDLEAI_OPENWEBUI_PASSWORD" : "MIDDLEAI_\(account.uppercased())"]
  }
  public func delete(account: String) throws {}
}

public struct CompositeCredentialStore: CredentialStore, Sendable {
  let primary: any CredentialStore
  let fallback: any CredentialStore
  public init(
    primary: any CredentialStore = KeychainCredentialStore(),
    fallback: any CredentialStore = EnvironmentCredentialStore()
  ) {
    self.primary = primary
    self.fallback = fallback
  }
  public func save(_ value: String, account: String) throws {
    try primary.save(value, account: account)
  }
  public func read(account: String) throws -> String? {
    try primary.read(account: account) ?? fallback.read(account: account)
  }
  public func delete(account: String) throws { try primary.delete(account: account) }
}
