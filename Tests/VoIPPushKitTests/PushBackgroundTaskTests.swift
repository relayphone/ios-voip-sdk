import Synchronization
import Testing
import VoIPPushDelivery
import VoIPTesting

@testable import VoIPPushKit

@Suite(.timeLimit(.minutes(1)))
struct PushBackgroundTaskTests {
  @Test(arguments: [false, true])
  func sdkAndWatchdogCompletionBothStartSettling(watchdogFires: Bool) async throws {
    let clock = TestClock()
    let execution = FakeBackgroundExecution()
    var ended = execution.ended.makeAsyncIterator()
    let task = PushBackgroundTask(execution: execution, clock: clock, settle: .seconds(2))
    let (completions, output) = AsyncStream.makeStream(of: Bool.self)
    var completed = completions.makeAsyncIterator()
    let delivery = task.delivery(
      finishing: { output.yield(true) }, watchdog: watchdogFires ? 0.01 : 3600)
    if !watchdogFires { delivery.finish() }
    #expect(await completed.next() == true)
    try await clock.waitForSleepers(count: 2)
    #expect(execution.endings.isEmpty)
    clock.advance(by: .seconds(2))
    #expect(await ended.next() == 1)
    delivery.finish()
    #expect(execution.endings == [1])
    #expect(clock.pendingSleepCount == 0)
  }

  @Test func beginsAtArrivalAndEndsAfterCompletionAndSettle() async throws {
    let clock = TestClock()
    let execution = FakeBackgroundExecution()
    var ended = execution.ended.makeAsyncIterator()
    let task = PushBackgroundTask(execution: execution, clock: clock, settle: .seconds(2))
    #expect(execution.begun == 1)
    try await clock.waitForSleepers()
    clock.advance(by: .seconds(3))
    #expect(execution.endings.isEmpty)
    task.completed()
    task.completed()
    try await clock.waitForSleepers(count: 2)
    clock.advance(by: .seconds(1))
    #expect(execution.endings.isEmpty)
    clock.advance(by: .seconds(1))
    #expect(await ended.next() == 1)
    #expect(execution.endings == [1])
    #expect(clock.pendingSleepCount == 0)
  }

  @Test func capsBackgroundTimeWhenCompletionNeverArrives() async throws {
    let clock = TestClock()
    let execution = FakeBackgroundExecution()
    var ended = execution.ended.makeAsyncIterator()
    _ = PushBackgroundTask(execution: execution, clock: clock, settle: .seconds(2))
    try await clock.waitForSleepers()
    clock.advance(by: .seconds(9))
    #expect(execution.endings.isEmpty)
    clock.advance(by: .seconds(1))
    #expect(await ended.next() == 1)
    #expect(execution.endings == [1])
  }

  @Test func capBoundsACompletionNearTheDeadline() async throws {
    let clock = TestClock()
    let execution = FakeBackgroundExecution()
    var ended = execution.ended.makeAsyncIterator()
    let task = PushBackgroundTask(execution: execution, clock: clock, settle: .seconds(2))
    try await clock.waitForSleepers()
    clock.advance(by: .seconds(9))
    task.completed()
    try await clock.waitForSleepers(count: 2)
    clock.advance(by: .seconds(1))
    #expect(await ended.next() == 1)
    #expect(clock.pendingSleepCount == 0)
    task.completed()
    #expect(execution.endings == [1])
  }

  @Test func expirationEndsOnceAndCancelsTimers() async throws {
    let clock = TestClock()
    let execution = FakeBackgroundExecution()
    let task = PushBackgroundTask(execution: execution, clock: clock, settle: .seconds(2))
    task.completed()
    try await clock.waitForSleepers(count: 2)
    execution.expire(1)
    execution.expire(1)
    task.completed()
    #expect(execution.endings == [1])
    #expect(clock.pendingSleepCount == 0)
  }

  @Test func expirationDuringBeginStillEndsTheReturnedTask() {
    let execution = FakeBackgroundExecution(expiresDuringBegin: true)
    let clock = TestClock()
    let task = PushBackgroundTask(execution: execution, clock: clock, settle: .seconds(2))
    task.completed()
    #expect(execution.begun == 1)
    #expect(execution.endings == [1])
  }

  @Test func overlappingPushesHoldIndependentTasks() async throws {
    let clock = TestClock()
    let execution = FakeBackgroundExecution()
    var ended = execution.ended.makeAsyncIterator()
    let first = PushBackgroundTask(execution: execution, clock: clock, settle: .seconds(2))
    try await clock.waitForSleepers()
    clock.advance(by: .seconds(1))
    let second = PushBackgroundTask(execution: execution, clock: clock, settle: .seconds(2))
    #expect(execution.begun == 2)
    first.completed()
    try await clock.waitForSleepers(count: 3)
    clock.advance(by: .seconds(2))
    #expect(await ended.next() == 1)
    #expect(execution.endings == [1])
    second.completed()
    try await clock.waitForSleepers(count: 2)
    clock.advance(by: .seconds(2))
    #expect(await ended.next() == 2)
    #expect(execution.endings == [1, 2])
    #expect(clock.pendingSleepCount == 0)
  }
}

private final class FakeBackgroundExecution: PushBackgroundExecution {
  private struct State {
    var expirations: [@Sendable () -> Void] = []
    var endings: [Int] = []
  }
  private let state = Mutex(State())
  private let expiresDuringBegin: Bool
  let ended: AsyncStream<Int>
  private let output: AsyncStream<Int>.Continuation

  init(expiresDuringBegin: Bool = false) {
    self.expiresDuringBegin = expiresDuringBegin
    (ended, output) = AsyncStream.makeStream(of: Int.self)
  }

  var begun: Int { state.withLock { $0.expirations.count } }
  var endings: [Int] { state.withLock { $0.endings } }

  func begin(expiration: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
    let id = state.withLock { state in
      state.expirations.append(expiration)
      return state.expirations.count
    }
    if expiresDuringBegin { expiration() }
    return {
      self.state.withLock { $0.endings.append(id) }
      self.output.yield(id)
    }
  }

  func expire(_ id: Int) {
    state.withLock { $0.expirations[id - 1] }()
  }
}
