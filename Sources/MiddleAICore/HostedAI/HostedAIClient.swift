import Foundation

public enum HostedAIProvider: String, Sendable {
  case openai
  case openrouter

  public var title: String { self == .openai ? "OpenAI" : "OpenRouter" }
  public var baseURL: URL {
    URL(string: self == .openai ? "https://api.openai.com/v1" : "https://openrouter.ai/api/v1")!
  }
  public var credentialAccount: String { "provider.\(rawValue).api_key" }
}

/// OpenAI-compatible hosted chat client. Conversations remain in MiddleAI's encrypted local
/// database; only the message context required for the current answer is sent to the provider.
public final class HostedAIClient: AssistantClientProtocol, @unchecked Sendable {
  private struct ModelEnvelope: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
  }
  private struct CompletionChunk: Decodable {
    struct Choice: Decodable {
      struct Delta: Decodable { let content: String? }
      let delta: Delta?
      let message: Delta?
    }
    let choices: [Choice]
  }

  public let provider: HostedAIProvider
  private let credentials: any CredentialStore
  private let session: URLSession

  public init(
    provider: HostedAIProvider, credentials: any CredentialStore,
    session: URLSession = .shared
  ) {
    self.provider = provider
    self.credentials = credentials
    self.session = session
  }

  public func authenticate() async throws {
    guard let key = try credentials.read(account: provider.credentialAccount),
      !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw MiddleAIError.authentication }
  }

  public func health() async throws {
    _ = try await models()
  }

  public func models() async throws -> [String] {
    try await authenticate()
    if provider == .openrouter {
      do { return try await loadModels(path: "models/user") } catch {
        return try await loadModels(path: "models")
      }
    }
    let models = try await loadModels(path: "models")
    let nonChatPrefixes = [
      "text-embedding", "whisper", "tts-", "dall-e", "omni-moderation", "babbage",
      "davinci", "gpt-image", "computer-use", "codex-mini",
    ]
    return models.filter { id in
      !nonChatPrefixes.contains(where: { id.lowercased().hasPrefix($0) })
    }
  }

  public func createChat(title: String, messages: [Message], model: String) async throws -> String {
    UUID().uuidString
  }

  public func send(
    messages: [Message], chatID: String, model: String,
    onToken: @escaping @Sendable (String) -> Void
  ) async throws -> String {
    guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MiddleAIError.noModel
    }
    let payload: [String: Any] = [
      "model": model,
      "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
      "stream": true,
    ]
    var request = try authorizedRequest(path: "chat/completions", method: "POST")
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw MiddleAIError.network("\(provider.title) lieferte keine HTTP-Antwort")
    }
    guard (200..<300).contains(http.statusCode) else {
      var body = ""
      for try await line in bytes.lines {
        body += line
        if body.count > 1_000 { break }
      }
      throw MiddleAIError.network(
        "\(provider.title) antwortet mit HTTP \(http.statusCode)\(Self.errorDetail(body))")
    }
    var complete = ""
    for try await line in bytes.lines {
      try Task.checkCancellation()
      guard line.hasPrefix("data:") else { continue }
      let raw = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
      if raw == "[DONE]" { break }
      guard let data = raw.data(using: .utf8),
        let chunk = try? JSONDecoder().decode(CompletionChunk.self, from: data),
        let token = chunk.choices.first.flatMap({ $0.delta?.content ?? $0.message?.content }),
        !token.isEmpty
      else { continue }
      complete += token
      onToken(token)
    }
    guard !complete.isEmpty else {
      throw MiddleAIError.invalidResponse("\(provider.title) hat keinen Antworttext geliefert")
    }
    return complete
  }

  public func cancel(chatID: String) async {}
  public func listChats() async throws -> [(id: String, title: String)] { [] }
  public func chatURL(id: String) -> URL {
    URL(
      string: provider == .openai
        ? "https://platform.openai.com/usage" : "https://openrouter.ai/activity")!
  }

  private func loadModels(path: String) async throws -> [String] {
    let request = try authorizedRequest(path: path)
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw MiddleAIError.network("\(provider.title) Modellliste: HTTP \(code)")
    }
    let envelope = try JSONDecoder().decode(ModelEnvelope.self, from: data)
    return Array(Set(envelope.data.map(\.id))).sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
  }

  private func authorizedRequest(path: String, method: String = "GET") throws -> URLRequest {
    guard let key = try credentials.read(account: provider.credentialAccount), !key.isEmpty else {
      throw MiddleAIError.authentication
    }
    var request = URLRequest(url: provider.baseURL.appendingPathComponent(path))
    request.httpMethod = method
    request.timeoutInterval = 180
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if provider == .openrouter {
      request.setValue("https://sschluet.github.io/middleai/", forHTTPHeaderField: "HTTP-Referer")
      request.setValue("MiddleAI", forHTTPHeaderField: "X-Title")
    }
    return request
  }

  private static func errorDetail(_ body: String) -> String {
    guard let data = body.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let error = root["error"] as? [String: Any],
      let message = error["message"] as? String, !message.isEmpty
    else { return "" }
    return ": \(String(message.prefix(400)))"
  }
}
