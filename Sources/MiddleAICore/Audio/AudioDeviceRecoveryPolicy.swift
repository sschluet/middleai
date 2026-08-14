import Foundation

/// Backoff used while Core Audio changes profiles after a default-device switch. Bluetooth
/// headsets commonly expose their microphone only after the output route has already changed.
public struct AudioDeviceRecoveryPolicy: Equatable, Sendable {
  public let retryDelaysNanoseconds: [UInt64]

  public init(
    retryDelaysNanoseconds: [UInt64] = [150_000_000, 300_000_000, 600_000_000, 900_000_000]
  ) {
    self.retryDelaysNanoseconds = retryDelaysNanoseconds
  }

  public var maximumAttempts: Int { retryDelaysNanoseconds.count + 1 }

  /// `failureCount` starts at one for the first failed attempt.
  public func delayNanoseconds(afterFailure failureCount: Int) -> UInt64? {
    guard failureCount > 0, failureCount <= retryDelaysNanoseconds.count else { return nil }
    return retryDelaysNanoseconds[failureCount - 1]
  }
}
