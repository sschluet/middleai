import Foundation
import XCTest

@testable import MiddleAICore

final class LocalRuntimeTests: XCTestCase {
  func testLocalAnswerProviderRoundTripAndFactory() throws {
    var config = AppConfig()
    config.assistant.provider = "local"
    config.localLLM.enabled = true
    config.localLLM.provider = "llama_cpp"
    config.localLLM.url = "http://127.0.0.1:18881"
    config.localLLM.model = "gemma-local"
    config.localLLM.answerTimeoutSeconds = 240
    config.localLLM.contextTokenBudget = 8_192

    let decoded = try ConfigLoader.parseYAML(ConfigLoader.renderYAML(config))
    XCTAssertEqual(decoded.assistantProviderTitle, "MiddleAI Lokal")
    XCTAssertEqual(decoded.assistantModel, "gemma-local")
    let client = try MiddleAIFactory.makeAssistantClient(
      config: decoded, credentials: KeychainCredentialStore())
    XCTAssertTrue(client is LocalAssistantClient)
  }

  func testStrictOfflineRejectsHostedProviderAndRemoteRedirectTargets() throws {
    var hosted = AppConfig()
    hosted.assistant.provider = "openai"
    hosted.openai.model = "test"
    hosted.privacy.strictOffline = true
    XCTAssertThrowsError(try ConfigLoader.parseYAML(ConfigLoader.renderYAML(hosted)))

    XCTAssertTrue(NetworkAccessPolicy.isLoopback(URL(string: "http://127.0.0.1:18881/v1")!))
    XCTAssertTrue(NetworkAccessPolicy.isLoopback(URL(string: "http://[::1]:18881/v1")!))
    XCTAssertFalse(NetworkAccessPolicy.isLoopback(URL(string: "https://api.openai.com/v1")!))
    XCTAssertFalse(NetworkAccessPolicy.isLoopback(URL(string: "http://example.com/v1")!))
  }

  func testLocalClientListsModelsAndStreamsResponse() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [LocalRuntimeURLProtocol.self]
    let client = try LocalAssistantClient(
      endpoint: URL(string: "http://127.0.0.1:18881")!, model: "local-test",
      sessionConfiguration: configuration,
      scheduler: InferenceScheduler(maximumConcurrentOperations: 1))

    let models = try await client.models()
    XCTAssertEqual(models, ["local-test"])
    let tokens = ThreadSafeStrings()
    let answer = try await client.send(
      messages: [Message(role: .user, content: "Test")], chatID: "chat",
      model: "local-test"
    ) { token in
      tokens.append(token)
    }
    XCTAssertEqual(answer, "Hallo lokal.")
    XCTAssertEqual(tokens.values.joined(), answer)
  }

  func testInferenceSchedulerReportsAndReleasesPermit() async throws {
    let scheduler = InferenceScheduler(maximumConcurrentOperations: 1)
    let value = try await scheduler.run(workload: .languageModel) { "fertig" }
    XCTAssertEqual(value, "fertig")
    let snapshot = await scheduler.snapshot()
    XCTAssertEqual(snapshot.maximumConcurrentOperations, 1)
    XCTAssertTrue(snapshot.active.isEmpty)
    XCTAssertTrue(snapshot.queued.isEmpty)
  }

  func testResourceRecommendationScalesWithMemory() {
    let small = LocalRuntimeResources(
      physicalMemoryBytes: 8 * 1_073_741_824, availableDiskBytes: nil,
      processorCount: 8, activeProcessorCount: 8)
    let medium = LocalRuntimeResources(
      physicalMemoryBytes: 24 * 1_073_741_824, availableDiskBytes: nil,
      processorCount: 10, activeProcessorCount: 10)
    XCTAssertEqual(small.recommendedMaximumModelBillions, 4)
    XCTAssertEqual(medium.recommendedMaximumModelBillions, 14)
  }
}

private final class ThreadSafeStrings: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []
  var values: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
  func append(_ value: String) {
    lock.lock()
    storage.append(value)
    lock.unlock()
  }
}

private final class LocalRuntimeURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let path = request.url?.path ?? ""
    let data: Data
    let contentType: String
    if path.hasSuffix("/models") {
      data = Data(#"{"data":[{"id":"local-test"}]}"#.utf8)
      contentType = "application/json"
    } else {
      let stream = """
        data: {"choices":[{"delta":{"content":"Hallo "},"finish_reason":null}]}

        data: {"choices":[{"delta":{"content":"lokal."},"finish_reason":"stop"}]}

        data: [DONE]

        """
      data = Data(stream.utf8)
      contentType = "text/event-stream"
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": contentType])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
