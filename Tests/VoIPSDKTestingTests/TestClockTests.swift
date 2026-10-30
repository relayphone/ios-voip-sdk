import Testing
import VoIPSDKTesting

@Suite(.timeLimit(.minutes(1)))
struct TestClockTests {
  @Test func timeMovesOnlyWhenAdvanced() {
    let clock = TestClock()
    let start = clock.now
    #expect(clock.now == start)
    clock.advance(by: .nanoseconds(123))
    #expect(start.duration(to: clock.now) == .nanoseconds(123))
    clock.advance(by: .zero)
    #expect(start.duration(to: clock.now) == .nanoseconds(123))
    #expect(clock.minimumResolution > .zero)
    clock.run()
    #expect(start.duration(to: clock.now) == .nanoseconds(123))
  }

  @Test func resumesOnlyDueSleepersIncludingEqualDeadlines() async throws {
    let clock = TestClock()
    let start = clock.now
    let late = Task { try await clock.sleep(until: start.advanced(by: .seconds(10))) }
    try await clock.waitForSleepers()
    let early = Task { try await clock.sleep(until: start.advanced(by: .seconds(2))) }
    try await clock.waitForSleepers(count: 2)
    let tied = Task { try await clock.sleep(until: start.advanced(by: .seconds(2))) }
    try await clock.waitForSleepers(count: 3)

    clock.advance(by: .seconds(1))
    #expect(clock.pendingSleepCount == 3)
    clock.advance(by: .seconds(1))
    try await early.value
    try await tied.value
    #expect(clock.pendingSleepCount == 1)
    #expect(start.duration(to: clock.now) == .seconds(2))
    clock.run()
    try await late.value
    #expect(start.duration(to: clock.now) == .seconds(10))
    #expect(clock.pendingSleepCount == 0)
  }

  @Test func pastDeadlinesDoNotSuspend() async throws {
    let clock = TestClock()
    try await clock.sleep(until: clock.now, tolerance: .seconds(100))
    try await clock.sleep(until: clock.now.advanced(by: .seconds(-1)))
    #expect(clock.pendingSleepCount == 0)
    try await clock.waitForSleepers(count: 0)
  }

  @Test func cancellationRemovesPendingSleep() async throws {
    let clock = TestClock()
    let task = Task { try await clock.sleep(for: .seconds(10)) }
    try await clock.waitForSleepers()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(clock.pendingSleepCount == 0)
    let now = clock.now
    clock.run()
    #expect(clock.now == now)
  }

  @Test func cancellationBeforeRegistrationDoesNotLeak() async {
    let clock = TestClock()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await clock.sleep(for: .seconds(10))
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(clock.pendingSleepCount == 0)
  }

  @Test func cancelledPastSleepStillThrows() async {
    let clock = TestClock()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await clock.sleep(until: clock.now)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test func cancellationRacingAdvanceResumesOnce() async throws {
    let clock = TestClock()
    for _ in 0..<100 {
      let task = Task { try await clock.sleep(for: .seconds(1)) }
      try await clock.waitForSleepers()
      await withTaskGroup(of: Void.self) { group in
        group.addTask { task.cancel() }
        group.addTask { clock.advance(by: .seconds(1)) }
      }
      do { try await task.value } catch is CancellationError {} catch { Issue.record(error) }
      #expect(clock.pendingSleepCount == 0)
    }
  }

  @Test func runCanDriveChainedSleepsWithRegistrationBarriers() async throws {
    let clock = TestClock()
    let start = clock.now
    let task = Task {
      try await clock.sleep(for: .seconds(1))
      try await clock.sleep(for: .seconds(2))
    }
    try await clock.waitForSleepers()
    clock.run()
    try await clock.waitForSleepers()
    clock.run()
    try await task.value
    #expect(start.duration(to: clock.now) == .seconds(3))
  }

  @Test func registrationWaitIsCancellable() async {
    let clock = TestClock()
    let waiter = Task { try await clock.waitForSleepers() }
    waiter.cancel()
    await #expect(throws: CancellationError.self) { try await waiter.value }
  }
}
