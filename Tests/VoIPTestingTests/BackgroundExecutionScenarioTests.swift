import Foundation
import Synchronization
import Testing
import VoIPTesting

@Suite(.timeLimit(.minutes(1)))
struct BackgroundExecutionScenarioTests {
  @Test func overlappingOwnersKeepIndependentIdentifiersAndAllowances() throws {
    let clock = TestClock()
    let scenario = BackgroundExecutionScenario(clock: clock)
    let wake = try #require(
      try scenario.begin(
        source: .pushWake, unverifiedAllowance: .seconds(2), expiration: {}))
    clock.advance(by: .seconds(1))
    let sdk = try #require(
      try scenario.begin(
        source: .sdkPushAssertion, unverifiedAllowance: .seconds(4), expiration: {}))
    let app = try #require(
      try scenario.begin(
        source: .applicationAssertion, unverifiedAllowance: .seconds(8), expiration: {}))
    #expect(Set([wake, sdk, app]).count == 3)
    #expect(scenario.assertions.map(\.due) == [.seconds(2), .seconds(5), .seconds(9)])
    #expect(
      scenario.assertions.map(\.source) == [.pushWake, .sdkPushAssertion, .applicationAssertion])
    #expect(scenario.end(wake))
    #expect(scenario.assertions.filter { !$0.ended }.map(\.id) == [sdk, app])
    #expect(scenario.history.map(\.sequence) == [1, 2, 3, 4])
    #expect(scenario.history.map(\.elapsed) == [.zero, .seconds(1), .seconds(1), .seconds(1)])
  }

  @Test func deniedBeginCreatesNoAssertionAndNeverDeliversExpiration() throws {
    let scenario = BackgroundExecutionScenario(clock: TestClock())
    let expirations = Mutex(0)
    scenario.enqueue(.deny)
    let id = try scenario.begin(
      source: .applicationAssertion, unverifiedAllowance: .seconds(1),
      expiration: { expirations.withLock { $0 += 1 } })
    #expect(id == nil && scenario.assertions.isEmpty)
    let row = try #require(scenario.history.first)
    guard case .denied(let denied, .applicationAssertion) = row.kind else {
      Issue.record("Missing typed denial")
      return
    }
    #expect(!scenario.expire(denied) && !scenario.end(denied))
    scenario.expireDueAssertions()
    #expect(expirations.withLock { $0 } == 0)
    #expect(scenario.history.count == 1)
  }

  @Test func invalidAllowanceDoesNotConsumeTheNextFailureControl() throws {
    let scenario = BackgroundExecutionScenario(clock: TestClock())
    scenario.enqueue(.deny)
    for duration in [Duration.zero, .seconds(-1)] {
      #expect(throws: BackgroundExecutionScenario.Failure.invalidAllowance) {
        try scenario.begin(
          source: .applicationAssertion, unverifiedAllowance: duration, expiration: {})
      }
    }
    #expect(scenario.history.isEmpty)
    let denied = try scenario.begin(
      source: .applicationAssertion, unverifiedAllowance: .seconds(1), expiration: {})
    #expect(denied == nil)
  }

  @Test func expirationBeforeReturnStillRequiresOwnerCleanup() throws {
    let scenario = BackgroundExecutionScenario(clock: TestClock())
    let expirations = Mutex(0)
    scenario.enqueue(.expireBeforeReturn)
    let id = try #require(
      try scenario.begin(
        source: .sdkPushAssertion, unverifiedAllowance: .seconds(10),
        expiration: { expirations.withLock { $0 += 1 } }))
    #expect(expirations.withLock { $0 } == 1)
    #expect(scenario.assertions.first?.expired == true)
    #expect(scenario.assertions.first?.ended == false)
    #expect(scenario.end(id))
    #expect(!scenario.expire(id))
    #expect(scenario.assertions.first?.endAttempts == 1)
    #expect(
      scenario.history.map(\.kind) == [
        .began(id, .sdkPushAssertion, unverifiedAllowance: .seconds(10)), .expired(id), .ended(id),
      ])
  }

  @Test func clockAdvanceAloneDoesNotDeliverCallbacksAndDueTimesAreExact() throws {
    let clock = TestClock()
    let scenario = BackgroundExecutionScenario(clock: clock)
    let expirations = Mutex(0)
    let id = try #require(
      try scenario.begin(
        source: .applicationAssertion, unverifiedAllowance: .seconds(2),
        expiration: { expirations.withLock { $0 += 1 } }))
    clock.advance(by: .seconds(2) - .nanoseconds(1))
    scenario.expireDueAssertions()
    #expect(expirations.withLock { $0 } == 0)
    clock.advance(by: .nanoseconds(1))
    #expect(expirations.withLock { $0 } == 0)
    scenario.expireDueAssertions()
    scenario.expireDueAssertions()
    #expect(expirations.withLock { $0 } == 1)
    #expect(scenario.history.last?.kind == .expired(id))
    #expect(scenario.history.last?.elapsed == .seconds(2))
    #expect(scenario.end(id))
  }

  @Test func dueCallbacksUseDeadlineThenBeginOrderAndMayReenterTheAdapter() throws {
    let clock = TestClock()
    let scenario = BackgroundExecutionScenario(clock: clock)
    let callbacks = Mutex<[Int]>([])
    let first = try #require(
      try scenario.begin(
        source: .applicationAssertion, unverifiedAllowance: .seconds(3),
        expiration: { callbacks.withLock { $0.append(3) } }))
    let second = try #require(
      try scenario.begin(
        source: .applicationAssertion, unverifiedAllowance: .seconds(1),
        expiration: {
          callbacks.withLock { $0.append(1) }
          // Reentry would deadlock if the fake delivered callbacks while holding its mutex.
          _ = scenario.end(first)
        }))
    let third = try #require(
      try scenario.begin(
        source: .sdkPushAssertion, unverifiedAllowance: .seconds(1),
        expiration: { callbacks.withLock { $0.append(2) } }))
    clock.advance(by: .seconds(5))
    scenario.expireDueAssertions()
    #expect(callbacks.withLock { $0 } == [1, 2])
    #expect(scenario.assertions.first?.ended == true)
    #expect(scenario.assertions.first?.expired == false)
    #expect(scenario.end(second) && scenario.end(third))
  }

  @Test func duplicateEndsAreVisibleAndEndCancelsLaterExpiration() throws {
    let clock = TestClock()
    let scenario = BackgroundExecutionScenario(clock: clock)
    let callback = Mutex(0)
    let id = try #require(
      try scenario.begin(
        source: .applicationAssertion, unverifiedAllowance: .seconds(1),
        expiration: { callback.withLock { $0 += 1 } }))
    #expect(scenario.end(id))
    #expect(!scenario.end(id))
    #expect(scenario.assertions.first?.endAttempts == 2)
    clock.advance(by: .seconds(10))
    scenario.expireDueAssertions()
    #expect(!scenario.expire(id))
    #expect(callback.withLock { $0 } == 0)
    #expect(scenario.history.count == 2)
  }

  @Test func aDifferentScenarioCannotEndOrExpireThisIdentifier() throws {
    let first = BackgroundExecutionScenario(clock: TestClock())
    let second = BackgroundExecutionScenario(clock: TestClock())
    let id = try #require(
      try first.begin(
        source: .applicationAssertion, unverifiedAllowance: .seconds(1), expiration: {}))
    #expect(!second.end(id) && !second.expire(id))
    #expect(second.history.isEmpty)
    #expect(first.assertions.first?.ended == false)
    #expect(first.end(id))
  }

  @Test func asyncObservationsMatchRetainedHistory() async throws {
    let scenario = BackgroundExecutionScenario(clock: TestClock())
    var iterator = scenario.observations.makeAsyncIterator()
    let id = try #require(
      try scenario.begin(
        source: .applicationAssertion, unverifiedAllowance: .seconds(1), expiration: {}))
    scenario.expire(id)
    scenario.end(id)
    for expected in scenario.history {
      #expect(await iterator.next() == expected)
    }
  }
}
