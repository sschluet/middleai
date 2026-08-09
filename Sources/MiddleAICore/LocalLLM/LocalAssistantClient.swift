import Foundation

/// OpenAI-compatible answer provider for an Ollama or llama.cpp server bound to loopback.
/// Conversation state remains in MiddleAI; the local server receives only the bounded context.
public final class LocalAssistantClient: AssistantClientProtocol, @unchecked Sendable {
  private struct ModelEnvelope: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
  }

  private struct CompletionChunk: Decodable, Sendable {
    struct ProviderError: Decodable, Sendable { let message: String? }
    struct Choice: Decodable, Sendable {
      struct Content: Decodable, Sendable {
        let content: String?
      }
      let delta: Content?
      let message: Content?
      let finishReason: String?

      enum CodingKeys: String, CodingKey {
        case delta
        case message
        case finishReason = "finish_reason"
      }
    }
    let choices: [Choice]?
    let error: ProviderError?
  }

  public let endpoint: URL
  public let configuredModel: String
  private let session: URLSession
  private let timeout: TimeInterval
  private let contextTokenBudget: Int
  private let scheduler: InferenceScheduler
  private let circuitBreaker: LocalLLMCircuitBreaker

  public init(
    endpoint: URL, model: String, timeout: TimeInterval = 300,
    contextTokenBudget: Int = 16_384,
    sessionConfiguration: URLSessionConfiguration? = nil,
    scheduler: InferenceScheduler = .shared, circuitBreakerFailures: Int = 3,
    circuitBreakerCooldown: TimeInterval = 30
  ) throws {
    try NetworkAccessPolicy.requireLoopback(endpoint)
    self.endpoint = endpoint
    self.configuredModel = model
    self.timeout = max(10, timeout)
    self.contextTokenBudget = max(512, contextTokenBudget)
    self.session = LoopbackOnlySession.make(
      timeout: timeout, configuration: sessionConfiguration)
    self.scheduler = scheduler
    self.circuitBreaker = LocalLLMCircuitBreaker(
      failureThreshold: circuitBreakerFailures, cooldown: circuitBreakerCooldown)
  }

  public func authenticate() async throws {
    try NetworkAccessPolicy.requireLoopback(endpoint)
  }

  public func health() async throws {
    _ = try await models()
  }

  public func models() async throws -> [String] {
    try NetworkAccessPolicy.requireLoopback(endpoint)
    var request = URLRequest(url: LocalLLMEndpoint.modelsURL(from: endpoint))
    request.timeoutInterval = min(timeout, 30)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw MiddleAIError.network("Lokaler Modellserver antwortet mit HTTP \(status)")
    }
    let envelope: ModelEnvelope
    do {
      envelope = try JSONDecoder().decode(ModelEnvelope.self, from: data)
    } catch {
      throw MiddleAIError.invalidResponse("Lokaler Modellserver lieferte keine Modellliste")
    }
    return Array(Set(envelope.data.map(\.id))).sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
  }

  public func createChat(title: String, messages: [Message], model: String) async throws -> String {
    UUID().uuidString
  }

  public func send(
    messages: [Message], chatID: String, model: String,
    onToken: @escaping @Sendable (String) -> Void
  ) async throws -> String {
    let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !selectedModel.isEmpty else { throw MiddleAIError.noModel }
    guard await circuitBreaker.allowsRequest() else {
      throw MiddleAIError.network(
        "Lokaler Modellserver pausiert nach wiederholten Fehlern. Bitte kurz warten.")
    }

    do {
      let result = try await scheduler.run(workload: .languageModel, priority: .userInitiated) {
        try await self.performSend(
          messages: messages, model: selectedModel, onToken: onToken)
      }
      await circuitBreaker.recordSuccess()
      return result
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      await circuitBreaker.recordFailure()
      throw error
    }
  }

  public func cancel(chatID: String) async {
    // MiddleAI cancels the task that owns URLSession.AsyncBytes. URLSession then closes the
    // request; local servers do not expose a portable per-chat cancellation endpoint.
  }

  public func listChats() async throws -> [(id: String, title: String)] { [] }

  public func chatURL(id: String) -> URL { endpoint }

  private func performSend(
    messages: [Message], model: String,
    onToken: @escaping @Sendable (String) -> Void
  ) async throws -> String {
    try Task.checkCancellation()
    try NetworkAccessPolicy.requireLoopback(endpoint)
    let preparedMessages = HostedContextWindow.prepared(
      messages, maximumEstimatedTokens: contextTokenBudget)
    let payload: [String: Any] = [
      "model": model,
      "messages": preparedMessages.map {
        ["role": $0.role.rawValue, "content": $0.content]
      },
      "stream": true,
    ]
    var request = URLRequest(url: LocalLLMEndpoint.completionsURL(from: endpoint))
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw MiddleAIError.network("Lokaler Modellserver lieferte keine HTTP-Antwort")
    }
    guard (200..<300).contains(http.statusCode) else {
      var detail = ""
      for try await line in bytes.lines {
        detail += line
        if detail.count >= 1_024 { break }
      }
      throw MiddleAIError.network(
        "Lokaler Modellserver antwortet mit HTTP \(http.statusCode)"
          + Self.errorDetail(detail))
    }

    var complete = ""
    var finishReason: String?
    var sawDone = false
    do {
      for try await line in bytes.lines {
        try Task.checkCancellation()
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let raw: String
        if trimmed.hasPrefix("data:") {
          raw = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        } else if trimmed.first == "{" {
          // A few OpenAI-compatible local servers emit newline-delimited JSON.
          raw = trimmed
        } else {
          continue
        }
        if raw == "[DONE]" {
          sawDone = true
          break
        }
        guard let data = raw.data(using: .utf8),
          let chunk = try? JSONDecoder().decode(CompletionChunk.self, from: data)
        else { continue }
        if let message = chunk.error?.message, !message.isEmpty {
          throw MiddleAIError.network("Lokaler Modellserver: \(String(message.prefix(400)))")
        }
        guard let choice = chunk.choices?.first else { continue }
        if let token = choice.delta?.content ?? choice.message?.content, !token.isEmpty {
          complete += token
          onToken(token)
        }
        finishReason = choice.finishReason ?? finishReason
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as MiddleAIError {
      throw error
    } catch {
      throw MiddleAIError.network("Der lokale Antwortstream wurde unterbrochen")
    }

    if finishReason == "length" {
      throw MiddleAIError.invalidResponse(
        "Das lokale Modell hat die Antwort am Kontextlimit abgeschnitten")
    }
    if ["tool_calls", "function_call"].contains(finishReason ?? "") {
      throw MiddleAIError.invalidResponse(
        "Das lokale Modell forderte einen nicht konfigurierten Werkzeugaufruf an")
    }
    guard sawDone || finishReason == "stop" || !complete.isEmpty else {
      throw MiddleAIError.invalidResponse("Lokaler Antwortstream endete ohne Abschluss")
    }
    guard !complete.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MiddleAIError.invalidResponse("Das lokale Modell lieferte keinen Antworttext")
    }
    return complete
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
