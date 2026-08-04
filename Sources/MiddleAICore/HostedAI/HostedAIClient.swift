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

/// OpenAI-compatible hosted chat client. Conversations remain in MiddleAI's permission-protected
/// local database; only the message context required for the current answer is sent to the
/// provider. The database itself is not encrypted; at-rest protection depends on macOS FileVault.
public final class HostedAIClient: AssistantClientProtocol, @unchecked Sendable {
  private struct ModelEnvelope: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
  }
  private struct CompletionChunk: Decodable, Sendable {
    struct ProviderError: Decodable, Sendable { let message: String? }
    struct Choice: Decodable, Sendable {
      struct Delta: Decodable, Sendable {
        struct ToolCall: Decodable, Sendable {}
        let content: String?
        let toolCalls: [ToolCall]?

        enum CodingKeys: String, CodingKey {
          case content
          case toolCalls = "tool_calls"
        }
      }
      let delta: Delta?
      let message: Delta?
      let finishReason: String?
      let error: ProviderError?

      enum CodingKeys: String, CodingKey {
        case delta
        case message
        case finishReason = "finish_reason"
        case error
      }
    }
    let choices: [Choice]?
    let error: ProviderError?
  }

  public let provider: HostedAIProvider
  private let credentials: any CredentialStore
  private let session: URLSession
  private let contextTokenBudget: Int
  private let maximumRateLimitRetries: Int
  private let retrySleeper: @Sendable (Duration) async throws -> Void

  public init(
    provider: HostedAIProvider, credentials: any CredentialStore,
    session: URLSession = .shared,
    contextTokenBudget: Int = HostedContextWindow.defaultTokenBudget,
    maximumRateLimitRetries: Int = 2,
    retrySleeper: @escaping @Sendable (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    }
  ) {
    self.provider = provider
    self.credentials = credentials
    self.session = session
    self.contextTokenBudget = max(512, contextTokenBudget)
    self.maximumRateLimitRetries = max(0, maximumRateLimitRetries)
    self.retrySleeper = retrySleeper
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
    let preparedMessages = HostedContextWindow.prepared(
      messages, maximumEstimatedTokens: contextTokenBudget)
    let payload: [String: Any] = [
      "model": model,
      "messages": preparedMessages.map { ["role": $0.role.rawValue, "content": $0.content] },
      "stream": true,
    ]
    let body = try JSONSerialization.data(withJSONObject: payload)
    var attempt = 0
    while true {
      try Task.checkCancellation()
      var request = try authorizedRequest(path: "chat/completions", method: "POST")
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      let (bytes, response) = try await session.bytes(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw MiddleAIError.network("\(provider.title) lieferte keine HTTP-Antwort")
      }
      if http.statusCode == 429 || http.statusCode == 503 {
        let errorBody = try await Self.readErrorBody(bytes.lines)
        guard attempt < maximumRateLimitRetries else {
          throw MiddleAIError.network(
            "\(provider.title) antwortet mit HTTP \(http.statusCode)"
              + Self.errorDetail(errorBody))
        }
        let delay = Self.retryDelay(response: http, attempt: attempt)
        attempt += 1
        try await retrySleeper(delay)
        continue
      }
      guard (200..<300).contains(http.statusCode) else {
        let errorBody = try await Self.readErrorBody(bytes.lines)
        throw MiddleAIError.network(
          "\(provider.title) antwortet mit HTTP \(http.statusCode)"
            + Self.errorDetail(errorBody))
      }
      return try await consumeCompletion(bytes.lines, onToken: onToken)
    }
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

  private func consumeCompletion<S: AsyncSequence>(
    _ lines: S, onToken: @escaping @Sendable (String) -> Void
  ) async throws -> String where S.Element == String {
    var complete = ""
    var finishReason: String?
    var requestedToolCall = false
    var sawDone = false
    do {
      for try await line in lines {
        try Task.checkCancellation()
        guard line.hasPrefix("data:") else { continue }
        let raw = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if raw == "[DONE]" {
          sawDone = true
          break
        }
        guard let data = raw.data(using: .utf8),
          let chunk = try? JSONDecoder().decode(CompletionChunk.self, from: data)
        else { continue }
        if let error = chunk.error?.message {
          throw MiddleAIError.network("\(provider.title): \(String(error.prefix(400)))")
        }
        guard let choice = chunk.choices?.first else { continue }
        if let error = choice.error?.message {
          throw MiddleAIError.network("\(provider.title): \(String(error.prefix(400)))")
        }
        if let token = choice.delta?.content ?? choice.message?.content, !token.isEmpty {
          complete += token
          onToken(token)
        }
        requestedToolCall =
          requestedToolCall || !(choice.delta?.toolCalls ?? []).isEmpty
          || !(choice.message?.toolCalls ?? []).isEmpty
        finishReason = choice.finishReason ?? finishReason
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as MiddleAIError {
      throw error
    } catch {
      throw MiddleAIError.network("\(provider.title) Stream wurde unterbrochen")
    }

    switch finishReason {
    case "length":
      throw MiddleAIError.invalidResponse(
        "\(provider.title) hat die Antwort am Token-Limit abgeschnitten.")
    case "tool_calls", "function_call":
      throw MiddleAIError.invalidResponse(
        "\(provider.title) hat einen Werkzeugaufruf angefordert, aber MiddleAI hat für diesen "
          + "Anbieter keine Werkzeuge konfiguriert.")
    case "content_filter":
      throw MiddleAIError.invalidResponse(
        "\(provider.title) hat die Antwort wegen eines Inhaltsfilters beendet.")
    case "error":
      throw MiddleAIError.network("\(provider.title) hat die Generierung mit einem Fehler beendet")
    case "stop": break
    case nil where sawDone: break
    case nil:
      throw MiddleAIError.invalidResponse(
        "\(provider.title) hat den Antwortstream ohne Abschluss beendet.")
    default:
      throw MiddleAIError.invalidResponse(
        "\(provider.title) meldet den unbekannten Abschlussgrund \(finishReason ?? "-").")
    }
    if requestedToolCall {
      throw MiddleAIError.invalidResponse(
        "\(provider.title) hat einen unvollständigen Werkzeugaufruf geliefert.")
    }
    guard !complete.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MiddleAIError.invalidResponse("\(provider.title) hat keinen Antworttext geliefert")
    }
    return complete
  }

  private static func readErrorBody<S: AsyncSequence>(_ lines: S) async throws -> String
  where S.Element == String {
    var body = ""
    for try await line in lines {
      body += line
      if body.count >= 1_024 { break }
    }
    return String(body.prefix(1_024))
  }

  private static func retryDelay(response: HTTPURLResponse, attempt: Int) -> Duration {
    let maximumSeconds = 8.0
    if let raw = response.value(forHTTPHeaderField: "Retry-After") {
      if let seconds = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return .milliseconds(Int64(min(maximumSeconds, max(0, seconds)) * 1_000))
      }
      for format in [
        "EEE',' dd MMM yyyy HH':'mm':'ss z", "EEEE',' dd-MMM-yy HH':'mm':'ss z",
        "EEE MMM d HH':'mm':'ss yyyy",
      ] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        if let date = formatter.date(from: raw) {
          let seconds = min(maximumSeconds, max(0, date.timeIntervalSinceNow))
          return .milliseconds(Int64(seconds * 1_000))
        }
      }
    }
    let seconds = min(maximumSeconds, 0.5 * pow(2, Double(attempt)))
    return .milliseconds(Int64(seconds * 1_000))
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
