import Foundation
import Testing
import VoIPTesting

@testable import VoIPPushKit

@Suite(.timeLimit(.minutes(1)))
struct PushBackgroundExecutionScenarioTests {
  private struct Adapter: PushBackgroundExecution {
    let scenario: BackgroundExecutionScenario
    var didEnd: @Sendable () -> Void = {}
    func begin(expiration: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
      guard
        let id = try? scenario.begin(
          source: .sdkPushAssertion, unverifiedAllowance: .seconds(10), expiration: expiration)
      else { return didEnd }
      return {
        scenario.end(id)
        didEnd()
      }
    }
  }

  @Test(arguments: [false, true])
  func realPushLifetimeEndsExactlyOnceAfterExpiration(expireBeforeReturn: Bool) throws {
    let clock = TestClock()
    let scenario = BackgroundExecutionScenario(clock: clock)
    if expireBeforeReturn { scenario.enqueue(.expireBeforeReturn) }
    let task = PushBackgroundTask(
      execution: Adapter(scenario: scenario), clock: clock, settle: .seconds(2))
    let id = try #require(scenario.assertions.first?.id)
    if !expireBeforeReturn { scenario.expire(id) }
    task.completed()
    scenario.expire(id)
    #expect(scenario.assertions.first?.ended == true)
    #expect(scenario.assertions.first?.endAttempts == 1)
    #expect(
      scenario.history.map(\.kind) == [
        .began(id, .sdkPushAssertion, unverifiedAllowance: .seconds(10)), .expired(id), .ended(id),
      ])
  }

  @Test func denialLeavesTheRealPushLifetimeWithoutAFakeAssertion() async throws {
    let clock = TestClock()
    let scenario = BackgroundExecutionScenario(clock: clock)
    scenario.enqueue(.deny)
    let (ended, output) = AsyncStream.makeStream(of: Bool.self)
    var iterator = ended.makeAsyncIterator()
    let task = PushBackgroundTask(
      execution: Adapter(scenario: scenario, didEnd: { output.yield(true) }),
      clock: clock, settle: .seconds(2))
    task.completed()
    try await clock.waitForSleepers(count: 2)
    clock.advance(by: .seconds(2))
    #expect(await iterator.next() == true)
    #expect(clock.pendingSleepCount == 0)
    #expect(scenario.assertions.isEmpty)
    #expect(scenario.history.count == 1)
  }
}
