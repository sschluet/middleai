import Foundation

/// Central policy used by local runtimes and strict-offline provider construction.
public enum NetworkAccessPolicy {
  public static func isLoopback(_ url: URL) -> Bool {
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      url.user == nil, url.password == nil
    else {
      return false
    }
    let host = url.host?.lowercased() ?? ""
    return host == "localhost" || host == "127.0.0.1" || host == "::1"
  }

  public static func requireLoopback(_ url: URL) throws {
    guard isLoopback(url) else {
      throw MiddleAIError.configuration(
        "Strict offline mode blocked a non-loopback network destination")
    }
  }
}

/// Prevents a trusted loopback server from redirecting MiddleAI to a remote host.
final class LoopbackOnlySessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(request.url.map(NetworkAccessPolicy.isLoopback) == true ? request : nil)
  }
}

enum LoopbackOnlySession {
  static func make(
    timeout: TimeInterval = 180, configuration supplied: URLSessionConfiguration? = nil
  ) -> URLSession {
    let configuration = supplied ?? URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = max(timeout, 300)
    configuration.waitsForConnectivity = false
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(
      configuration: configuration, delegate: LoopbackOnlySessionDelegate(), delegateQueue: nil)
  }
}
