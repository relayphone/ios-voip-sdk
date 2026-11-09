import Testing
import VoIPCore

@testable import VoIPConversationsMapping

@Suite
struct IncomingOutcomeBufferTests {
  @Test
  func preservesArrivalOrderAndFlushesOnce() {
    var buffer = IncomingOutcomeBuffer()
    let outcomes: [JSONValue] = [.string("filtered"), .string("failed"), .string("presented")]
    for outcome in outcomes {
      #expect(buffer.receive(outcome, listenerAttached: false).isEmpty)
    }
    #expect(buffer.flush() == outcomes)
    #expect(buffer.flush().isEmpty)
  }

  @Test
  func dropsOldestBeyondSixteenOutcomes() {
    var buffer = IncomingOutcomeBuffer()
    let outcomes = (0..<20).map { JSONValue.string("call-\($0)") }
    for outcome in outcomes {
      #expect(buffer.receive(outcome, listenerAttached: false).isEmpty)
    }
    #expect(buffer.flush() == Array(outcomes.suffix(16)))
  }

  @Test
  func attachedListenerReceivesEachOutcomeWithoutBufferingItAgain() {
    var buffer = IncomingOutcomeBuffer()
    let cold = JSONValue.string("cold-call")
    let live = JSONValue.string("live-call")
    #expect(buffer.receive(cold, listenerAttached: false).isEmpty)
    var delivered = buffer.flush()
    delivered += buffer.receive(live, listenerAttached: true)
    #expect(delivered == [cold, live])
    #expect(buffer.flush().isEmpty)
    #expect(buffer.receive(cold, listenerAttached: false).isEmpty)
    #expect(buffer.flush() == [cold])
    #expect(buffer.flush().isEmpty)
  }
}
