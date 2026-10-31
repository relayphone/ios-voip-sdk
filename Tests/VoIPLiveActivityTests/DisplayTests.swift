import Foundation
import Testing
import VoIPCore

@testable import VoIPLiveActivity

@Suite struct DisplayTests {
  private let attributes = CallPreviewAttributes(callID: callID, parties: [alice])

  private func display(
    _ state: CallPreviewAttributes.ContentState = firstState, isStale: Bool = false,
    attributes: CallPreviewAttributes? = nil
  ) -> CallPreviewDisplay {
    CallPreviewDisplay(attributes: attributes ?? self.attributes, state: state, isStale: isStale)
  }

  private func described(_ display: CallPreviewDisplay) -> String? {
    if case .described(let resource) = display.status { resource.key } else { nil }
  }

  @Test func showsThePartysNameOrHandle() throws {
    #expect(display().name == "Alice")
    let unnamed = try Party(handle: Handle(kind: .phoneNumber, value: "+14155550123"))
    #expect(
      display(attributes: CallPreviewAttributes(callID: callID, parties: [unnamed])).name
        == "+14155550123")
    #expect(display(attributes: CallPreviewAttributes(callID: callID, parties: [])).name == nil)
  }

  @Test(arguments: [
    (CallPreviewStatus.filtered, "Call silenced"),
    (.answeredElsewhere, "Answered on another device"),
    (.policy, "Call in progress"), (.ended, "Call ended"),
  ])
  func describesEachStatus(_ status: CallPreviewStatus, _ words: String) {
    var state = firstState
    state.status = status
    #expect(described(display(state)) == words)
  }

  @Test func prefersTheAppsWords() {
    var state = firstState
    state.statusText = "Your assistant is answering"
    guard case .text(let text) = display(state).status else {
      Issue.record("The display shows the app's words")
      return
    }
    #expect(text == "Your assistant is answering")
  }

  @Test func timesTheCallUntilItEnds() {
    #expect(display().timerStart == startedAt)
    #expect(display(.ended(firstState)).timerStart == nil)
  }

  @Test func offersJoinWhileJoinable() {
    #expect(display().showsJoin)
    var state = firstState
    state.isJoinable = false
    #expect(!display(state).showsJoin)
    state.isJoinable = true
    state.status = .ended
    #expect(!display(state).showsJoin)
    #expect(display(isStale: true).showsJoin)
  }

  @Test func saysThatUpdatesAreDelayedInsteadOfAnOldSnippet() {
    var state = firstState
    state.snippet = "They asked whether you can call back after six."
    #expect(display(state).snippet == state.snippet)
    #expect(!display(state).showsDelay)
    #expect(display(state, isStale: true).snippet == nil)
    #expect(display(state, isStale: true).showsDelay)
    // An ended preview's state doesn't go out of date.
    state.status = .ended
    #expect(!display(state, isStale: true).showsDelay)
    #expect(display(state, isStale: true).snippet == state.snippet)
  }

  @Test func showsTheKindOfCall() {
    #expect(display().symbol == "phone.fill")
    let video = CallPreviewAttributes(callID: callID, parties: [alice], hasVideo: true)
    #expect(display(attributes: video).symbol == "video.fill")
    #expect(display(.ended(firstState), attributes: video).symbol == "phone.down.fill")
  }
}
