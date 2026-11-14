import CKSimProtocol
import Foundation
import Testing

@testable import CKSimRuntime

struct RuntimeCallTimelineTests {
  @Test func previewWithoutAFrameworkReportHasNoReportTimestamp() {
    var history = RuntimeCallTimeline()
    let id = UUID()
    history.update(id, now: 100, reported: false) { $0.state = .previewing }
    #expect(history.calls[id]?.reportedAtMS == nil)
  }
  @Test func answerOffsetUsesRingStartAndPastOffsetsAreImmediate() {
    #expect(
      RuntimeCallTimeline.answerDelay(rangAtMS: 1000, nowMS: 4000, afterMS: 21000) == .seconds(18))
    #expect(RuntimeCallTimeline.answerDelay(rangAtMS: 1000, nowMS: 24000, afterMS: 21000) == .zero)
  }
  @Test func retentionKeepsRecentEndedCallsAndEveryLiveCall() throws {
    var history = RuntimeCallTimeline()
    let live = UUID()
    history.update(live, now: 0) { $0.state = .ringing }
    let old = UUID()
    history.update(old, now: 1) {
      $0.state = .ended
      $0.endedAtMS = 1
    }
    for time in 2...257 {
      history.update(UUID(), now: UInt64(time)) {
        $0.state = .ended
        $0.endedAtMS = UInt64(time)
      }
    }
    #expect(history.calls.count == 257)
    #expect(history.calls[old] == nil)
    #expect(history.calls[live]?.reportedAtMS == 0)
    let retained = try #require(history.calls.values.first { $0.state == .ended })
    #expect(
      try JSONDecoder().decode(RetainedCall.self, from: JSONEncoder().encode(retained)) == retained)
  }
}
