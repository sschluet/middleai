import Foundation
import Network

public enum LocalInputEvent: Sendable {
  case started(String)
  case completed(InputResult)
  case failed(String)
}

@MainActor public final class LocalInputServer {
  private struct QueuedInput {
    let text: String
    let source: String
  }

  private var listener: NWListener?
  private let engine: MiddleAIEngine
  private let config: AppConfig.API
  private let credentials: any CredentialStore
  private let onEvent: (@MainActor (LocalInputEvent) -> Void)?
  private var queuedInputs: [QueuedInput] = []
  private var isDrainingQueue = false
  public private(set) var isRunning = false
  public init(
    engine: MiddleAIEngine, config: AppConfig.API,
    credentials: any CredentialStore = CompositeCredentialStore(),
    onEvent: (@MainActor (LocalInputEvent) -> Void)? = nil
  ) {
    self.engine = engine
    self.config = config
    self.credentials = credentials
    self.onEvent = onEvent
  }
  public func start() throws {
    guard config.bind == "127.0.0.1" || config.bind == "::1" else {
      throw MiddleAIError.configuration("HTTP listener must bind to loopback")
    }
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host(config.bind), port: NWEndpoint.Port(rawValue: config.port)!)
    let listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in self?.accept(connection) }
    }
    listener.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        self?.isRunning = {
          if case .ready = state { return true }
          return false
        }()
      }
    }
    listener.start(queue: .global(qos: .userInitiated))
    self.listener = listener
  }
  public func stop() {
    listener?.cancel()
    listener = nil
    queuedInputs.removeAll()
    isDrainingQueue = false
    isRunning = false
  }
  private func accept(_ connection: NWConnection) {
    connection.start(queue: .global(qos: .userInitiated))
    receive(connection, buffer: Data())
  }
  private func receive(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) {
      [weak self] data, _, complete, error in
      guard let self else { return }
      var combined = buffer
      if let data { combined.append(data) }
      if let request = HTTPRequest.parse(combined) {
        Task { @MainActor in await self.respond(to: request, on: connection) }
      } else if !complete && error == nil {
        Task { @MainActor in self.receive(connection, buffer: combined) }
      } else {
        Task { @MainActor in
          self.send(status: 400, json: ["error": "invalid request"], on: connection)
        }
      }
    }
  }
  private func respond(to request: HTTPRequest, on connection: NWConnection) async {
    guard request.method == "POST", request.path == "/input" || request.path == "/command" else {
      send(status: 404, json: ["error": "not found"], on: connection)
      return
    }
    if config.tokenRequired {
      let expected = try? credentials.read(account: "api_token")
      guard let expected, request.headers["authorization"] == "Bearer \(expected)" else {
        send(status: 401, json: ["error": "unauthorized"], on: connection)
        return
      }
    }
    let jsonObject = try? JSONSerialization.jsonObject(with: request.body)
    let payload = jsonObject as? [String: Any]
    let text =
      payload != nil
      ? (payload?["text"] as? String) ?? ""
      : String(data: request.body, encoding: .utf8) ?? ""
    let source = (payload?["source"] as? String) ?? request.headers["x-middleai-source"] ?? "http"
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      send(status: 422, json: ["error": "text is required"], on: connection)
      return
    }

    if request.path == "/command" {
      let requestID = UUID().uuidString
      queuedInputs.append(QueuedInput(text: text, source: source))
      send(
        status: 202,
        json: [
          "accepted": true,
          "request_id": requestID,
          "message": "MiddleAI accepted the question and will answer separately.",
        ], on: connection)
      startQueueIfNeeded()
      return
    }

    await process(text: text, source: source, on: connection)
  }

  private func startQueueIfNeeded() {
    guard !isDrainingQueue else { return }
    isDrainingQueue = true
    Task { @MainActor [weak self] in
      await self?.drainQueue()
    }
  }

  private func drainQueue() async {
    while !queuedInputs.isEmpty {
      let input = queuedInputs.removeFirst()
      await process(text: input.text, source: input.source, on: nil)
    }
    isDrainingQueue = false
  }

  private func process(text: String, source: String, on connection: NWConnection?) async {
    onEvent?(.started(text))
    do {
      try await engine.client.authenticate()
      let result = try await engine.handle(text: text, source: source)
      onEvent?(.completed(result))
      guard let connection else { return }
      switch result {
      case .response(let answer, let id):
        send(status: 200, json: ["response": answer, "conversation_id": id], on: connection)
      case .local(let value): send(status: 200, json: ["local": value], on: connection)
      case .clarification(let value):
        send(status: 409, json: ["clarification": value], on: connection)
      }
    } catch {
      onEvent?(.failed(error.localizedDescription))
      if let connection {
        send(status: 502, json: ["error": error.localizedDescription], on: connection)
      }
    }
  }
  private func send(status: Int, json: [String: Any], on connection: NWConnection) {
    let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
    let reason =
      [
        200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized",
        404: "Not Found", 409: "Conflict", 422: "Unprocessable Entity", 502: "Bad Gateway",
      ][status] ?? "Error"
    let header =
      "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    connection.send(
      content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
  }
}

private struct HTTPRequest {
  let method: String
  let path: String
  let headers: [String: String]
  let body: Data
  static func parse(_ data: Data) -> HTTPRequest? {
    guard let marker = Data("\r\n\r\n".utf8).range(in: data) else { return nil }
    let head = data[..<marker.lowerBound]
    guard let text = String(data: head, encoding: .utf8) else { return nil }
    let lines = text.components(separatedBy: "\r\n")
    let first = lines.first?.split(separator: " ") ?? []
    guard first.count >= 2 else { return nil }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      let p = line.split(separator: ":", maxSplits: 1)
      if p.count == 2 {
        headers[String(p[0]).lowercased()] = p[1].trimmingCharacters(in: .whitespaces)
      }
    }
    let start = marker.upperBound
    let length = Int(headers["content-length"] ?? "0") ?? 0
    guard data.count - start >= length else { return nil }
    return HTTPRequest(
      method: String(first[0]), path: String(first[1]), headers: headers,
      body: data.subdata(in: start..<(start + length)))
  }
}

extension Data {
  fileprivate func range(in data: Data) -> Range<Data.Index>? { data.range(of: self) }
}
