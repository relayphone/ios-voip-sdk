import CKSimProtocol
import Foundation
import Testing

@testable import CKSimRuntime

struct ConfirmedVideoTests {
  @Test func onlyConfirmedChangesEnterTheHistory() throws {
    var history = RuntimeCallTimeline()
    let id = UUID()
    history.update(id, now: 1) { $0.state = .connected }
    #expect(history.calls[id]?.hasVideo == false)
    #expect(history.confirmVideo(id, hasVideo: false, now: 2) == nil)
    #expect(history.confirmVideo(id, hasVideo: true, now: 3) == .init(atMS: 3, hasVideo: true))
    #expect(history.confirmVideo(id, hasVideo: true, now: 4) == nil)
    #expect(history.confirmVideo(id, hasVideo: false, now: 5) == .init(atMS: 5, hasVideo: false))
    #expect(
      history.calls[id]?.videoChanges == [
        .init(atMS: 3, hasVideo: true), .init(atMS: 5, hasVideo: false),
      ])
  }
  @Test func endedAndUnknownReportsCannotCreateVideoHistory() {
    var history = RuntimeCallTimeline()
    let id = UUID()
    #expect(history.confirmVideo(id, hasVideo: true, now: 1) == nil)
    #expect(history.calls.isEmpty)
    history.update(id, now: 2) { $0.state = .connected }
    _ = history.confirmVideo(id, hasVideo: true, now: 3)
    history.update(id, now: 4) {
      $0.state = .ended
      $0.endedAtMS = 4
    }
    #expect(history.confirmVideo(id, hasVideo: false, now: 5) == nil)
    #expect(history.calls[id]?.hasVideo == true)
    #expect(history.calls[id]?.videoChanges.count == 1)
    history.beginIfEnded(id)
    history.update(id, now: 6) { $0.state = .ringing }
    #expect(history.calls[id]?.hasVideo == false)
    #expect(history.calls[id]?.videoChanges.isEmpty == true)
  }
}
