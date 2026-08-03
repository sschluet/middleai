import Foundation
import OSLog

public struct MiddleAILogger: Sendable {
  /// Only non-content operational fields may enter the unified log. New call sites must opt in
  /// here instead of relying on an incomplete deny-list for secrets and user text.
  public static let allowedMetadataKeys: Set<String> = [
    "confidence", "decision", "length", "latency_ms", "model_id", "provider", "request_id",
    "source", "status",
  ]
  private let logger = Logger(subsystem: "de.middleai.app", category: "runtime")
  public init() {}
  public func event(_ name: String, metadata: [String: String] = [:]) {
    let safeName = Self.safeEventName(name)
    let safe = Self.sanitizedMetadata(metadata)
    logger.info(
      "event=\(safeName, privacy: .public) metadata=\(String(describing: safe), privacy: .public)")
  }
  public func error(_ name: String) {
    logger.error("error=\(Self.safeEventName(name), privacy: .public)")
  }

  public static func sanitizedMetadata(_ metadata: [String: String]) -> [String: String] {
    let allowedValueCharacters = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/+-")
    return metadata.reduce(into: [:]) { result, entry in
      let key = entry.key.lowercased()
      guard allowedMetadataKeys.contains(key), entry.value.count <= 96,
        entry.value.unicodeScalars.allSatisfy(allowedValueCharacters.contains)
      else { return }
      result[key] = entry.value
    }
  }

  private static func safeEventName(_ value: String) -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.-")
    guard !value.isEmpty, value.unicodeScalars.allSatisfy(allowed.contains) else {
      return "invalid_event"
    }
    return value
  }
}
