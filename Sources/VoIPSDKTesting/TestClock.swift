import os

/// A manually advanced clock for testing time-dependent code without elapsed wall time.
///
/// Sleepers are resumed by deadline, then by registration order for equal deadlines.
/// The task executor determines the order in which resumed tasks execute. Await a
/// task's observable effects before advancing time again to test chained sleeps.
public final class TestClock: Clock, Sendable {
  /// Uses the same monotonic instant representation as the production clock.
  public typealias Instant = ContinuousClock.Instant

  private struct Sleeper {
    let sequence: UInt64
    let deadline: Instant
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct State {
    var now = ContinuousClock().now
    var sequence: UInt64 = 0
    var sleepers: [Sleeper] = []
    var registrations:
      [(sequence: UInt64, count: Int, continuation: CheckedContinuation<Void, any Error>)] = []
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Creates an independent clock starting at the current continuous instant.
  public init() {}

  /// The current virtual instant; reading it never advances time.
  public var now: Instant { state.withLock { $0.now } }

  /// The number of registered sleeps that have not expired or been cancelled.
  public var pendingSleepCount: Int { state.withLock { $0.sleepers.count } }

  /// Virtual time can be advanced with attosecond precision.
  public var minimumResolution: Duration { Duration(secondsComponent: 0, attosecondsComponent: 1) }

  /// Suspends until virtual time reaches `deadline`, or the task is cancelled.
  ///
  /// Tolerance is ignored: this clock always uses the exact requested deadline.
  /// Past deadlines return immediately, unless the task has been cancelled.
  public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
    let sequence = nextSequence()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let registrations = state.withLock { state in
          if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
          } else if deadline <= state.now {
            continuation.resume()
          } else {
            state.sleepers.append(
              Sleeper(sequence: sequence, deadline: deadline, continuation: continuation))
            state.sleepers.sort {
              $0.deadline == $1.deadline ? $0.sequence < $1.sequence : $0.deadline < $1.deadline
            }
          }
          let ready = state.registrations.filter { $0.count <= state.sleepers.count }
          state.registrations.removeAll { $0.count <= state.sleepers.count }
          return ready
        }
        for registration in registrations { registration.continuation.resume() }
      }
    } onCancel: {
      let sleeper = self.state.withLock { state -> Sleeper? in
        guard let index = state.sleepers.firstIndex(where: { $0.sequence == sequence }) else {
          return nil
        }
        return state.sleepers.remove(at: index)
      }
      sleeper?.continuation.resume(throwing: CancellationError())
    }
    try Task.checkCancellation()
  }

  /// Advances by a nonnegative duration, resuming all sleepers due at the new instant.
  ///
  /// This does not wait for resumed tasks to execute or register further sleeps.
  public func advance(by duration: Duration) {
    precondition(duration >= .zero, "TestClock cannot move backwards")
    resumeSleepers { $0.now.advanced(by: duration) }
  }

  /// Advances to the final currently registered deadline and resumes those sleepers.
  ///
  /// Returns immediately when no sleeps are pending. Sleeps registered by resumed
  /// tasks require another advance or run after awaiting the tasks' observable effects.
  public func run() {
    resumeSleepers { $0.sleepers.last?.deadline ?? $0.now }
  }

  /// Waits until at least `count` sleeps have been registered and remain pending.
  ///
  /// Use this before advancing to synchronize with tasks starting their first sleep.
  /// The count must be nonnegative. Cancellation removes this registration barrier
  /// and throws `CancellationError` without affecting any sleeping tasks.
  public func waitForSleepers(count: Int = 1) async throws {
    precondition(count >= 0, "Sleeper count must be nonnegative")
    let sequence = nextSequence()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        state.withLock { state in
          if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
          } else if state.sleepers.count >= count {
            continuation.resume()
          } else {
            state.registrations.append((sequence, count, continuation))
          }
        }
      }
    } onCancel: {
      let registration = self.state.withLock { state -> CheckedContinuation<Void, any Error>? in
        guard let index = state.registrations.firstIndex(where: { $0.sequence == sequence }) else {
          return nil
        }
        return state.registrations.remove(at: index).continuation
      }
      registration?.resume(throwing: CancellationError())
    }
    try Task.checkCancellation()
  }

  private func nextSequence() -> UInt64 {
    state.withLock { state in
      defer { state.sequence += 1 }
      return state.sequence
    }
  }

  private func resumeSleepers(until deadline: @Sendable (State) -> Instant) {
    let due = state.withLock { state in
      state.now = deadline(state)
      let due = state.sleepers.prefix { $0.deadline <= state.now }
      state.sleepers.removeFirst(due.count)
      return Array(due)
    }
    for sleeper in due { sleeper.continuation.resume() }
  }
}
