import Foundation
import Synchronization

#if SWIFT_PACKAGE
  import VoIPPushDelivery
#endif

/// Begins background execution synchronously, and returns its end operation.
protocol PushBackgroundExecution: Sendable {
  func begin(expiration: @escaping @Sendable () -> Void) -> @Sendable () -> Void
}

/// Keeps one push alive through completion and settling, or until expiration or the cap.
final class PushBackgroundTask: Sendable {
  private struct State {
    var end: (@Sendable () -> Void)?
    var ended = false
    var completed = false
    var timers: [Task<Void, Never>] = []
  }

  private let state = Mutex(State())
  private let clock: any Clock<Duration>
  private let settle: Duration

  init(
    execution: any PushBackgroundExecution, clock: any Clock<Duration>, settle: Duration,
    cap: Duration = .seconds(10)
  ) {
    self.clock = clock
    self.settle = settle
    // Capture the cap's deadline at arrival, before beginning background execution.
    let capTimer = timer(clock: clock, after: cap)
    let end = execution.begin { self.end() }
    let ended = state.withLock { state in
      if state.ended { return true }
      state.end = end
      return false
    }
    if ended { end() }
    install(capTimer)
  }

  /// Called after the system's push completion returns, including the watchdog's completion.
  func completed() {
    let shouldSettle = state.withLock { state in
      guard !state.ended, !state.completed else { return false }
      state.completed = true
      return true
    }
    if shouldSettle {
      let clock = self.clock
      install(timer(clock: clock, after: settle))
    }
  }

  /// Connects both SDK completion and watchdog completion to the same settle period.
  func delivery(finishing finish: @escaping () -> Void, watchdog: TimeInterval) -> VSPushCompletion
  {
    VSPushCompletion(
      completion: {
        finish()
        self.completed()
      }, watchdog: watchdog)
  }

  private func timer<C: Clock>(clock: C, after duration: Duration) -> Task<Void, Never>
  where C.Duration == Duration {
    let deadline = clock.now.advanced(by: duration)
    return Task {
      do {
        try await clock.sleep(until: deadline, tolerance: nil)
        end()
      } catch {}
    }
  }

  private func install(_ timer: Task<Void, Never>) {
    let ended = state.withLock { state in
      if state.ended { return true }
      state.timers.append(timer)
      return false
    }
    if ended { timer.cancel() }
  }

  private func end() {
    let (end, timers) = state.withLock { state in
      state.ended = true
      defer {
        state.end = nil
        state.timers = []
      }
      return (state.end, state.timers)
    }
    for timer in timers { timer.cancel() }
    end?()
  }
}
