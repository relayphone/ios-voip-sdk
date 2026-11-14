import CKSimProtocol
import Foundation
import Synchronization
import Testing
import VoIPTesting

@testable import CKSimRuntime

struct PreparedPushPayloadTests {
  @Test func aNonObjectFailsBeforeSchedulingWithTheOriginalError() {
    #expect(throws: PreparedPushPayload.ValidationError.invalid("payload object required")) {
      try PreparedPushPayload([1, 2])
    }
  }

  @Test func encodingErrorsAreReturnedToTheCaller() {
    #expect(throws: EncodingError.self) {
      try PreparedPushPayload(PushPayload(fields: ["number": .number(.infinity)]))
    }
  }

  @Test func duplicatesReuseThePayloadEncodedAtAcceptance() async throws {
    final class Counted: Encodable {
      let count = Mutex(0)
      func encode(to encoder: any Encoder) throws {
        count.withLock { $0 += 1 }
        try PushPayload(fields: [
          "integer": .unsigned(.max), "nested": .array([.null, .boolean(true)]),
        ])
        .encode(to: encoder)
      }
    }
    let counted = Counted()
    let payload = try PreparedPushPayload(counted)
    #expect(counted.count.withLock { $0 } == 1)
    let plan = PushDeliverySchedule(id: UUID(), faults: try PushDeliveryFaults(duplicate: 2))
    let clock = TestClock()
    let attempts = Mutex(0)
    try await plan.run(clock: clock, startingAt: clock.now) { _ in
      #expect((payload.dictionary["integer"] as? NSNumber)?.uint64Value == UInt64.max)
      #expect((payload.dictionary["nested"] as? NSArray)?.count == 2)
      attempts.withLock { $0 += 1 }
    }
    #expect(attempts.withLock { $0 } == 3)
    #expect(counted.count.withLock { $0 } == 1)
  }
}
