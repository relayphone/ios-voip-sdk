import CKSimProtocol
import Foundation
import Synchronization
import Testing
import VoIPTesting

@testable import CKSimRuntime

@Suite(.timeLimit(.minutes(1)))
struct PushDeliveryScheduleTests {
  @Test func delayAndSpacingStartIndependentReportingWindowsAtDelivery() async throws {
    let clock = TestClock()
    let start = clock.now
    let id = UUID()
    let plan = PushDeliverySchedule(
      id: id, faults: try PushDeliveryFaults(delayMS: 5000, duplicate: 2, spacingMS: 2000))
    #expect(plan.deliveries.first?.id == id)
    #expect(Set(plan.deliveries.map(\.id)).count == 3)
    let obligations = Mutex(PushReportingObligations())
    let received = Mutex<[UUID]>([])
    let task = Task {
      try await plan.run(clock: clock, startingAt: start) { delivery in
        received.withLock { $0.append(delivery.id) }
        #expect(
          obligations.withLock {
            $0.receive(
              delivery.id.uuidString, required: true,
              now: start.duration(to: clock.now), budget: .seconds(4.4))
          })
      }
    }
    defer { task.cancel() }
    try await clock.waitForSleepers()
    clock.advance(by: .milliseconds(4999))
    #expect(received.withLock { $0.isEmpty })
    #expect(obligations.withLock { $0.awaitingReport() == nil })
    clock.advance(by: .milliseconds(1))
    try await clock.waitForSleepers()
    #expect(received.withLock { $0 == [id] })
    let firstToken = try #require(obligations.withLock { $0.deadlineToken(id.uuidString) })
    #expect(
      obligations.withLock {
        !$0.expire(id.uuidString, token: firstToken, now: .seconds(5))
      })
    clock.advance(by: .seconds(2))
    try await clock.waitForSleepers()
    #expect(received.withLock { $0.count == 2 })
    clock.advance(by: .seconds(2))
    try await task.value
    #expect(received.withLock { $0 == plan.deliveries.map(\.id) })
    #expect(
      obligations.withLock {
        $0.entered(id.uuidString, call: UUID(), alreadyKnown: false, now: .seconds(9))
      })
    let duplicate = plan.deliveries[1].id.uuidString
    let token = try #require(obligations.withLock { $0.deadlineToken(duplicate) })
    #expect(obligations.withLock { !$0.expire(duplicate, token: token, now: .seconds(11.399)) })
    #expect(obligations.withLock { $0.expire(duplicate, token: token, now: .seconds(11.4)) })
  }

  @Test func droppingEveryCopyCreatesNoReportingObligations() async throws {
    let clock = TestClock()
    let plan = PushDeliverySchedule(
      id: UUID(), faults: try PushDeliveryFaults(drop: true, duplicate: 3))
    let dropped = Mutex<[UUID]>([])
    try await plan.run(clock: clock, startingAt: clock.now) { delivery in
      #expect(delivery.dropped)
      dropped.withLock { $0.append(delivery.id) }
    }
    #expect(dropped.withLock { Set($0).count == 4 })
  }

  @Test func cancellationDoesNotDeliverPendingCopies() async throws {
    let clock = TestClock()
    let plan = PushDeliverySchedule(id: UUID(), faults: try PushDeliveryFaults(delayMS: 1000))
    let task = Task {
      try await plan.run(clock: clock, startingAt: clock.now) { _ in
        Issue.record("A cancelled schedule delivered a push")
      }
    }
    try await clock.waitForSleepers()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(clock.pendingSleepCount == 0)
  }
}
