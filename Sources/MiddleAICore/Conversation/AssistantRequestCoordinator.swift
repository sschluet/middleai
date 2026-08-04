import Foundation

/// Serializes provider requests without treating ordinary parallel callers as user barge-in.
/// Cancellation while waiting removes only that caller; `MiddleAIEngine.interrupt()` remains the
/// explicit mechanism for cancelling the active provider operation.
@MainActor final class AssistantRequestCoordinator {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, Error>
  }

  private var activeID: UUID?
  private var waiters: [Waiter] = []

  func acquire(_ id: UUID) async throws {
    try Task.checkCancellation()
    if activeID == nil {
      activeID = id
      return
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        waiters.append(Waiter(id: id, continuation: continuation))
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancelWaiting(id) }
    }
    do {
      try Task.checkCancellation()
    } catch {
      // Promotion and cancellation can race. If this waiter was promoted just before its
      // cancellation handler ran, release the permit so the FIFO cannot become stuck.
      release(id)
      throw error
    }
  }

  func release(_ id: UUID) {
    guard activeID == id else { return }
    activeID = nil
    promoteNext()
  }

  private func cancelWaiting(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(throwing: CancellationError())
  }

  private func promoteNext() {
    guard activeID == nil, !waiters.isEmpty else { return }
    let waiter = waiters.removeFirst()
    activeID = waiter.id
    waiter.continuation.resume()
  }
}
