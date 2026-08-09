import Foundation

/// Coordinates memory-intensive local inference so STT, generation, TTS and background indexing
/// do not all contend for unified memory at once. Callers select a priority; interactive work is
/// promoted ahead of queued background work without interrupting an already running operation.
public actor InferenceScheduler {
  public enum Workload: String, Codable, CaseIterable, Sendable {
    case speechRecognition
    case languageModel
    case speechSynthesis
    case embeddings
    case backgroundIndexing
  }

  public enum Priority: Int, Codable, Comparable, Sendable {
    case background = 0
    case utility = 10
    case userInitiated = 20
    case realtime = 30

    public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  public struct Snapshot: Equatable, Sendable {
    public let maximumConcurrentOperations: Int
    public let active: [Workload: Int]
    public let queued: [Workload: Int]
  }

  private struct Waiter {
    let id: UUID
    let sequence: UInt64
    let workload: Workload
    let priority: Priority
    let continuation: CheckedContinuation<Void, Error>
  }

  public static let shared = InferenceScheduler()

  private let maximumConcurrentOperations: Int
  private var active: [UUID: Workload] = [:]
  private var waiters: [Waiter] = []
  private var nextSequence: UInt64 = 0

  public init(maximumConcurrentOperations: Int = 1) {
    self.maximumConcurrentOperations = max(1, maximumConcurrentOperations)
  }

  public func run<T: Sendable>(
    workload: Workload, priority: Priority = .userInitiated,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let id = UUID()
    try await acquire(id: id, workload: workload, priority: priority)
    defer { release(id: id) }
    return try await operation()
  }

  public func snapshot() -> Snapshot {
    Snapshot(
      maximumConcurrentOperations: maximumConcurrentOperations,
      active: Dictionary(grouping: active.values, by: { $0 }).mapValues(\.count),
      queued: Dictionary(grouping: waiters.map(\.workload), by: { $0 }).mapValues(\.count))
  }

  private func acquire(id: UUID, workload: Workload, priority: Priority) async throws {
    try Task.checkCancellation()
    if active.count < maximumConcurrentOperations {
      active[id] = workload
      return
    }
    let sequence = nextSequence
    nextSequence &+= 1
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        waiters.append(
          Waiter(
            id: id, sequence: sequence, workload: workload, priority: priority,
            continuation: continuation))
      }
    } onCancel: {
      Task { await self.cancelWaiting(id: id) }
    }
    do {
      try Task.checkCancellation()
    } catch {
      // Promotion and task cancellation may race. Release a permit that was just promoted.
      release(id: id)
      throw error
    }
  }

  private func release(id: UUID) {
    guard active.removeValue(forKey: id) != nil else { return }
    promote()
  }

  private func cancelWaiting(id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(throwing: CancellationError())
  }

  private func promote() {
    while active.count < maximumConcurrentOperations, !waiters.isEmpty {
      let best = waiters.indices.max { lhs, rhs in
        let left = waiters[lhs]
        let right = waiters[rhs]
        if left.priority == right.priority { return left.sequence > right.sequence }
        return left.priority < right.priority
      }!
      let waiter = waiters.remove(at: best)
      active[waiter.id] = waiter.workload
      waiter.continuation.resume()
    }
  }
}
