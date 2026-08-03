import Foundation
import Network
import Security

public enum LocalInputEvent: Sendable {
  case started(String)
  case completed(InputResult)
  case failed(String)
}

@MainActor public final class LocalInputServer {
  nonisolated public static let tokenAccount = "local_http_token"
  private static let maximumHeaderBytes = 16_384
  private static let retainedRequestStates = 128

  private struct QueuedInput {
    let id: String
    let text: String
    let source: String
  }

  private var listener: NWListener?
  private let engine: MiddleAIEngine
  private let config: AppConfig.API
  private let credentials: any CredentialStore
  private let onEvent: (@MainActor (LocalInputEvent) -> Void)?
  private var queuedInputs: [QueuedInput] = []
  private var requestStates: [String: String] = [:]
  private var requestStateOrder: [String] = []
  private var activeQueuedRequestID: String?
  private var activeQueuedTask: Task<Void, Never>?
  private var activeSynchronousRequests = 0
  private var isDrainingQueue = false
  private var receiveTimeouts: [UUID: Task<Void, Never>] = [:]
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
    if config.tokenRequired { _ = try ensureLocalAPIToken() }
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
    activeQueuedTask?.cancel()
    activeQueuedTask = nil
    activeQueuedRequestID = nil
    for timeout in receiveTimeouts.values { timeout.cancel() }
    receiveTimeouts.removeAll()
    queuedInputs.removeAll()
    isDrainingQueue = false
    isRunning = false
  }

  /// Returns the existing local-only HTTP token or creates a cryptographically random one.
  /// The OpenWebUI API key intentionally uses a different Keychain account.
  @discardableResult public func ensureLocalAPIToken() throws -> String {
    try Self.ensureLocalAPIToken(in: credentials)
  }

  @discardableResult nonisolated public static func ensureLocalAPIToken(
    in credentials: any CredentialStore
  ) throws -> String {
    if let token = try credentials.read(account: tokenAccount), !token.isEmpty { return token }
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw MiddleAIError.configuration("Could not generate the local API token")
    }
    let token = Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    try credentials.save(token, account: tokenAccount)
    return token
  }

  private func accept(_ connection: NWConnection) {
    let connectionID = UUID()
    connection.start(queue: .global(qos: .userInitiated))
    receiveTimeouts[connectionID] = Task { @MainActor [weak self, weak connection] in
      guard let self, let connection else { return }
      do { try await Task.sleep(for: .seconds(config.requestTimeoutSeconds)) } catch { return }
      guard receiveTimeouts.removeValue(forKey: connectionID) != nil else { return }
      send(status: 408, json: ["error": "request timeout"], on: connection)
    }
    receive(connection, id: connectionID, buffer: Data())
  }

  private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      [weak self] data, _, complete, error in
      guard let self else { return }
      var combined = buffer
      if let data { combined.append(data) }
      Task { @MainActor in
        guard self.receiveTimeouts[id] != nil else { return }
        switch LocalHTTPRequest.parse(
          combined, maximumHeaderBytes: Self.maximumHeaderBytes,
          maximumBodyBytes: self.config.maximumBodyBytes)
        {
        case .complete(let request):
          self.receiveTimeouts.removeValue(forKey: id)?.cancel()
          await self.respond(to: request, on: connection)
        case .incomplete where !complete && error == nil:
          self.receive(connection, id: id, buffer: combined)
        case .tooLarge(let kind):
          self.receiveTimeouts.removeValue(forKey: id)?.cancel()
          self.send(
            status: kind == .header ? 431 : 413,
            json: ["error": kind == .header ? "headers too large" : "body too large"],
            on: connection)
        case .invalid, .incomplete:
          self.receiveTimeouts.removeValue(forKey: id)?.cancel()
          self.send(status: 400, json: ["error": "invalid request"], on: connection)
        }
      }
    }
  }

  private func respond(to request: LocalHTTPRequest, on connection: NWConnection) async {
    if request.method == "GET", request.path == "/health" {
      send(status: 200, json: ["status": "ok", "queue_depth": queuedInputs.count], on: connection)
      return
    }
    guard authorize(request) else {
      send(status: 401, json: ["error": "unauthorized"], on: connection)
      return
    }
    if request.method == "GET", request.path.hasPrefix("/requests/") {
      let id = String(request.path.dropFirst("/requests/".count))
      guard let state = requestStates[id] else {
        send(status: 404, json: ["error": "request not found"], on: connection)
        return
      }
      send(status: 200, json: ["request_id": id, "status": state], on: connection)
      return
    }
    if request.method == "POST", request.path.hasPrefix("/requests/"),
      request.path.hasSuffix("/cancel")
    {
      let prefix = "/requests/"
      let id = String(request.path.dropFirst(prefix.count).dropLast("/cancel".count))
      guard cancelRequest(id) else {
        send(status: 404, json: ["error": "request not found or already finished"], on: connection)
        return
      }
      send(status: 200, json: ["request_id": id, "status": "cancelled"], on: connection)
      return
    }
    guard request.method == "POST", request.path == "/input" || request.path == "/command" else {
      send(status: 404, json: ["error": "not found"], on: connection)
      return
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
      guard queuedInputs.count < config.maximumQueueDepth else {
        send(status: 429, json: ["error": "command queue is full"], on: connection)
        return
      }
      let requestID = UUID().uuidString
      setRequestState("accepted", id: requestID)
      queuedInputs.append(QueuedInput(id: requestID, text: text, source: source))
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

    guard activeSynchronousRequests < config.maximumConcurrentRequests else {
      send(status: 429, json: ["error": "too many active requests"], on: connection)
      return
    }
    activeSynchronousRequests += 1
    defer { activeSynchronousRequests -= 1 }
    await process(text: text, source: source, on: connection)
  }

  private func authorize(_ request: LocalHTTPRequest) -> Bool {
    guard config.tokenRequired else { return true }
    guard let expected = try? credentials.read(account: Self.tokenAccount) else {
      return false
    }
    let prefix = "Bearer "
    guard let supplied = request.headers["authorization"], supplied.hasPrefix(prefix) else {
      return false
    }
    return constantTimeEqual(String(supplied.dropFirst(prefix.count)), expected)
  }

  private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    var difference = UInt(left.count ^ right.count)
    let count = max(left.count, right.count)
    for index in 0..<count {
      let l = index < left.count ? left[index] : 0
      let r = index < right.count ? right[index] : 0
      difference |= UInt(l ^ r)
    }
    return difference == 0
  }

  private func startQueueIfNeeded() {
    guard !isDrainingQueue else { return }
    isDrainingQueue = true
    Task { @MainActor [weak self] in await self?.drainQueue() }
  }

  private func drainQueue() async {
    while !queuedInputs.isEmpty {
      let input = queuedInputs.removeFirst()
      guard requestStates[input.id] != "cancelled" else { continue }
      while activeSynchronousRequests >= config.maximumConcurrentRequests {
        do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
      }
      activeSynchronousRequests += 1
      activeQueuedRequestID = input.id
      setRequestState("running", id: input.id)
      let task = Task { @MainActor [weak self] in
        guard let self else { return }
        await process(text: input.text, source: input.source, on: nil, requestID: input.id)
      }
      activeQueuedTask = task
      await task.value
      activeSynchronousRequests -= 1
      activeQueuedTask = nil
      activeQueuedRequestID = nil
    }
    isDrainingQueue = false
  }

  private func cancelRequest(_ id: String) -> Bool {
    if let index = queuedInputs.firstIndex(where: { $0.id == id }) {
      queuedInputs.remove(at: index)
      setRequestState("cancelled", id: id)
      return true
    }
    if activeQueuedRequestID == id {
      activeQueuedTask?.cancel()
      engine.interrupt()
      setRequestState("cancelled", id: id)
      return true
    }
    return false
  }

  private func setRequestState(_ state: String, id: String) {
    if requestStates[id] == nil { requestStateOrder.append(id) }
    requestStates[id] = state
    while requestStateOrder.count > Self.retainedRequestStates {
      requestStates.removeValue(forKey: requestStateOrder.removeFirst())
    }
  }

  private func process(
    text: String, source: String, on connection: NWConnection?, requestID: String? = nil
  ) async {
    onEvent?(.started(text))
    do {
      try Task.checkCancellation()
      try await engine.client.authenticate()
      let result = try await engine.handle(text: text, source: source)
      try Task.checkCancellation()
      onEvent?(.completed(result))
      if let requestID { setRequestState("completed", id: requestID) }
      guard let connection else { return }
      switch result {
      case .response(let answer, let id):
        send(status: 200, json: ["response": answer, "conversation_id": id], on: connection)
      case .local(let value): send(status: 200, json: ["local": value], on: connection)
      case .clarification(let value):
        send(status: 409, json: ["clarification": value], on: connection)
      }
    } catch is CancellationError {
      if let requestID { setRequestState("cancelled", id: requestID) }
      if let connection { send(status: 499, json: ["error": "cancelled"], on: connection) }
    } catch {
      onEvent?(.failed(error.localizedDescription))
      if let requestID { setRequestState("failed", id: requestID) }
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
        404: "Not Found", 408: "Request Timeout", 409: "Conflict", 413: "Content Too Large",
        422: "Unprocessable Entity", 429: "Too Many Requests",
        431: "Request Header Fields Too Large", 499: "Client Closed Request", 502: "Bad Gateway",
      ][status] ?? "Error"
    let header =
      "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
    connection.send(
      content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
  }
}

public enum LocalHTTPRequestSizeKind: Sendable {
  case header
  case body
}

public enum LocalHTTPRequestParseResult: Sendable {
  case incomplete
  case complete(LocalHTTPRequest)
  case invalid
  case tooLarge(LocalHTTPRequestSizeKind)
}

public struct LocalHTTPRequest: Sendable {
  public let method: String
  public let path: String
  public let headers: [String: String]
  public let body: Data

  public static func parse(
    _ data: Data, maximumHeaderBytes: Int = 16_384,
    maximumBodyBytes: Int = 1_048_576
  ) -> LocalHTTPRequestParseResult {
    guard let marker = data.range(of: Data("\r\n\r\n".utf8)) else {
      return data.count > maximumHeaderBytes ? .tooLarge(.header) : .incomplete
    }
    guard marker.lowerBound <= maximumHeaderBytes else { return .tooLarge(.header) }
    let head = data[..<marker.lowerBound]
    guard let text = String(data: head, encoding: .utf8) else { return .invalid }
    let lines = text.components(separatedBy: "\r\n")
    let first = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
    guard first.count == 3, first[2].hasPrefix("HTTP/1.") else { return .invalid }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard !line.isEmpty else { continue }
      let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { return .invalid }
      let key = String(parts[0]).lowercased()
      guard headers[key] == nil else { return .invalid }
      headers[key] = parts[1].trimmingCharacters(in: .whitespaces)
    }
    guard headers["transfer-encoding"] == nil else { return .invalid }
    let length: Int
    if let rawLength = headers["content-length"] {
      guard let parsed = Int(rawLength), parsed >= 0 else { return .invalid }
      length = parsed
    } else {
      length = 0
    }
    guard length <= maximumBodyBytes else { return .tooLarge(.body) }
    let start = marker.upperBound
    guard data.count - start >= length else { return .incomplete }
    guard data.count == start + length else { return .invalid }
    let method = String(first[0]).uppercased()
    let rawPath = String(first[1])
    guard !rawPath.contains("\r"), !rawPath.contains("\n") else { return .invalid }
    return .complete(
      LocalHTTPRequest(
        method: method, path: rawPath, headers: headers,
        body: data.subdata(in: start..<(start + length))))
  }
}
