import Foundation
import OSLog

public struct MiddleAILogger: Sendable {
  private let logger = Logger(subsystem: "de.middleai.app", category: "runtime")
  public init() {}
  public func event(_ name: String, metadata: [String: String] = [:]) {
    let safe = metadata.filter {
      !["password", "token", "prompt", "content"].contains($0.key.lowercased())
    }
    logger.info(
      "event=\(name, privacy: .public) metadata=\(String(describing: safe), privacy: .public)")
  }
  public func error(_ name: String) { logger.error("error=\(name, privacy: .public)") }
}
