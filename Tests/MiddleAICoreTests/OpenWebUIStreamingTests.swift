import Foundation
import XCTest

@testable import MiddleAICore

final class OpenWebUIStreamingTests: XCTestCase {
  func testSSEStreamingAndCompletionLifecycle() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StreamingURLProtocol.self]
    let client = OpenWebUIClient(
      baseURL: URL(string: "https://example.test")!, auth: StreamingStaticAuth(),
      session: URLSession(configuration: configuration))

    StreamingURLProtocol.handler = { request in
      switch request.url?.path {
      case "/api/models":
        return (200, Data(#"{"data":[{"id":"test-model"}]}"#.utf8))
      case "/api/v1/chats/test-chat":
        return (200, Data("{}".utf8))
      case "/api/chat/completions":
        let body = try streamingRequestJSON(request)
        XCTAssertEqual(body["stream"] as? Bool, true)
        return (
          200,
          Data(
            ("data: {\"choices\":[{\"delta\":{\"content\":\"Hallo \"}}]}\n\n"
              + "data: {\"choices\":[{\"delta\":{\"content\":\"Welt\"}}]}\n\n"
              + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
              + "data: [DONE]\n\n").utf8)
        )
      case "/api/chat/completed":
        let body = try streamingRequestJSON(request)
        let message = body["message"] as? [String: Any]
        XCTAssertEqual(message?["content"] as? String, "Hallo Welt")
        return (
          200, Data(#"{"message":{"role":"assistant","content":"Hallo Welt final"}}"#.utf8)
        )
      default:
        return (404, Data())
      }
    }

    try await client.authenticate()
    _ = try await client.models()
    let tokens = StreamingTokenStore()
    let result = try await client.send(
      messages: [Message(role: .user, content: "Test")], chatID: "test-chat",
      model: "test-model"
    ) { tokens.append($0) }

    XCTAssertEqual(tokens.values, ["Hallo ", "Welt"])
    XCTAssertEqual(result, "Hallo Welt final")
  }

  func testAsyncAcknowledgementPollsPersistedAssistantIncrementally() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StreamingURLProtocol.self]
    let client = OpenWebUIClient(
      baseURL: URL(string: "https://example.test")!, auth: StreamingStaticAuth(),
      session: URLSession(configuration: configuration))
    let polls = StreamingCounter()

    StreamingURLProtocol.handler = { request in
      switch request.url?.path {
      case "/api/models":
        return (200, Data(#"{"data":[{"id":"test-model"}]}"#.utf8))
      case "/api/chat/completions":
        return (200, Data(#"{"status":true,"task_ids":["task-1"]}"#.utf8))
      case "/api/v1/chats/test-chat" where request.httpMethod == "GET":
        let done = polls.increment() > 1
        let content = done ? "Teil eins und zwei" : "Teil eins"
        return (
          200,
          Data(
            "{\"chat\":{\"history\":{\"currentId\":\"assistant\",\"messages\":{\"assistant\":{\"id\":\"assistant\",\"role\":\"assistant\",\"content\":\"\(content)\",\"done\":\(done)}}}}}"
              .utf8)
        )
      case "/api/chat/completed", "/api/v1/chats/test-chat":
        return (200, Data("{}".utf8))
      default:
        return (404, Data())
      }
    }

    try await client.authenticate()
    _ = try await client.models()
    let tokens = StreamingTokenStore()
    let result = try await client.send(
      messages: [Message(role: .user, content: "Test")], chatID: "test-chat",
      model: "test-model"
    ) { tokens.append($0) }

    XCTAssertEqual(tokens.values, ["Teil eins", " und zwei"])
    XCTAssertEqual(result, "Teil eins und zwei")
  }
}

private struct StreamingStaticAuth: AuthProvider {
  func token(baseURL: URL, session: URLSession) async throws -> String { "test-token" }
}

private final class StreamingTokenStore: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []
  var values: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
  func append(_ token: String) {
    lock.lock()
    storage.append(token)
    lock.unlock()
  }
}

private final class StreamingCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0
  func increment() -> Int {
    lock.lock()
    defer { lock.unlock() }
    storage += 1
    return storage
  }
}

private final class StreamingURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, data) = try Self.handler?(request) ?? (500, Data())
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil,
        headerFields: ["Content-Type": "text/event-stream"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }
  override func stopLoading() {}
}

private func streamingRequestJSON(_ request: URLRequest) throws -> [String: Any] {
  var data = request.httpBody ?? Data()
  if data.isEmpty, let stream = request.httpBodyStream {
    stream.open()
    defer { stream.close() }
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
  }
  return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}
