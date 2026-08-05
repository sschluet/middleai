import Foundation

public enum ActivationGestureDecision: Equatable, Sendable {
  case waitingForSecondTap
  case activate
}

/// Distinguishes an intentional double tap from ordinary use of a modifier key. The caller owns
/// the clock so the state machine remains deterministic in tests and across event sources.
public struct ActivationGestureGate<Key: Hashable & Sendable>: Sendable {
  public let maximumInterval: TimeInterval
  private var pending: (key: Key, pressedAt: TimeInterval)?

  public init(maximumInterval: TimeInterval = 0.45) {
    self.maximumInterval = maximumInterval
  }

  public mutating func register(
    _ key: Key, requiresDoubleTap: Bool, at timestamp: TimeInterval
  ) -> ActivationGestureDecision {
    guard requiresDoubleTap else {
      pending = nil
      return .activate
    }
    if let pending, pending.key == key, timestamp >= pending.pressedAt,
      timestamp - pending.pressedAt <= maximumInterval
    {
      self.pending = nil
      return .activate
    }
    pending = (key, timestamp)
    return .waitingForSecondTap
  }

  public mutating func clear() { pending = nil }
}
