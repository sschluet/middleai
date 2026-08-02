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
    try delete(account: account)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
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
