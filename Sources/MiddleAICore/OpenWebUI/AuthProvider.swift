import Foundation

public protocol AuthProvider: Sendable {
  func token(baseURL: URL, session: URLSession) async throws -> String
}

public struct PasswordAuthProvider: AuthProvider {
  public let username: String
  private let credentials: any CredentialStore
  public init(username: String, credentials: any CredentialStore) {
    self.username = username
    self.credentials = credentials
  }
  public func token(baseURL: URL, session: URLSession) async throws -> String {
    guard let password = try credentials.read(account: "password"), !username.isEmpty else {
      throw MiddleAIError.authentication
    }
    var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/auths/signin"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "email": username, "password": password,
    ])
    let (data, response) = try await session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw MiddleAIError.authentication
    }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let token = json?["token"] as? String else { throw MiddleAIError.authentication }
    return token
  }
}

public struct BearerTokenAuthProvider: AuthProvider {
  private let credentials: any CredentialStore
  private let account: String
  public init(credentials: any CredentialStore, account: String = "api_token") {
    self.credentials = credentials
    self.account = account
  }
  public func token(baseURL: URL, session: URLSession) async throws -> String {
    guard let value = try credentials.read(account: account), !value.isEmpty else {
      throw MiddleAIError.authentication
    }
    return value
  }
}

public typealias APIKeyAuthProvider = BearerTokenAuthProvider
