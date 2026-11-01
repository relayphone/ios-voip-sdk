import Foundation
import Testing
import VoIPCore
import VoIPTesting

@testable import VoIPLiveActivity

@MainActor
@Suite struct JoinTests {
  /// A harness whose center holds a preview that the servers started before the app ran, after
  /// reading the event that the observer replays for it.
  private func harnessWithPushedPreview() async throws -> (Harness, LiveActivityID) {
    let center = FakeLiveActivityCenter()
    let activity = center.startFromPush(CallPreviewAttributes(filtered), state: firstState)
    let h = Harness(center: center)
    #expect(try await h.next() == .started(callID))
    return (h, activity)
  }

  /// The call that joining creates for a preview that the client doesn't know.
  private let adopted = IncomingCall(
    id: callID, parties: [alice], metadata: ["room": "room-1"],
    presentationPolicy: PresentationPolicy(incoming: .preview))

  @Test func joinsAPreviewThatTheClientKnows() async throws {
    let h = Harness()
    let activity = try await h.preview()
    try await h.previews.join(callID)
    #expect(h.client.requests == [.join(callID)])
    #expect(h.client.joins.isEmpty)

    var connecting = filtered
    connecting.status = .connecting
    h.send(.performed(.join(callID), connecting))
    #expect(try await h.next() == .ended(callID))
    #expect(h.center.records.last == .end(activity, nil, .immediate))
    #expect(h.client.requests == [.join(callID)])
  }

  @Test func joinsAPreviewThatTheServersStartedFromItsDetails() async throws {
    let (h, activity) = try await harnessWithPushedPreview()
    try await h.previews.join(callID)
    #expect(h.client.joins == [adopted])
    #expect(h.client.requests == [.join(callID)])
    // Joining the call doesn't start a second Live Activity.
    try await h.expectNoEvents()
    #expect(h.center.records.count { $0.isRequest } == 1)  // The marker's.

    var connecting = filtered
    connecting.status = .connecting
    h.send(.performed(.join(callID), connecting))
    #expect(try await h.next() == .ended(callID))
    #expect(h.center.records.last == .end(activity, nil, .immediate))
    // The joined call is the app's now.
    #expect(!h.client.requests.contains(.end(callID)))
  }

  @Test func endsACreatedCallWhenItsPreviewEnds() async throws {
    let (h, activity) = try await harnessWithPushedPreview()
    try await h.previews.join(callID)
    h.center.send(.ended(activity))
    #expect(try await h.next() == .ended(callID))
    try await until { h.client.requests.last == .end(callID) }
  }

  @Test func endsACreatedCallWhenTheAppEndsItsPreview() async throws {
    let (h, activity) = try await harnessWithPushedPreview()
    try await h.previews.join(callID)
    await h.previews.end(callID)
    #expect(try await h.next() == .ended(callID))
    #expect(h.center.records.last == .end(activity, .ended(firstState), .immediate))
    #expect(h.client.requests.last == .end(callID))
  }

  @Test func endsACreatedCallThatReturnsToAPreviewThatNothingShows() async throws {
    let (h, activity) = try await harnessWithPushedPreview()
    try await h.previews.join(callID)
    try await h.expectNoEvents()
    h.center.send(.ended(activity))
    #expect(try await h.next() == .ended(callID))
    // The join failed after the preview ended, which returns the call to its preview.
    var returned = filtered
    returned.status = .previewing(.policy)
    h.send(.previewStarted(returned))
    try await until { h.client.requests.count { $0 == .end(callID) } == 2 }
    try await h.expectNoEvents()
    #expect(h.center.records.count { $0.isRequest } == 2)  // The markers'.
  }

  @Test func joiningAPreviewWhoseCallEndedFailsWithItsStatus() async throws {
    let (h, _) = try await harnessWithPushedPreview()
    // The app's servers said that the call ended before the app knew it.
    h.client.joinError = .notAllowed(.ended(.endedRemotely))
    await #expect(throws: CallPreviewError.join(.notAllowed(.ended(.endedRemotely)))) {
      try await h.previews.join(callID)
    }
    #expect(h.client.joins == [adopted])
  }

  @Test func leavesACallItDidNotCreateWhenItsPreviewEnds() async throws {
    let h = Harness()
    let activity = try await h.preview()
    try await h.previews.join(callID)
    h.center.send(.ended(activity))
    #expect(try await h.next() == .ended(callID))
    try await h.expectNoEvents()
    #expect(h.client.requests == [.join(callID)])
  }

  @Test func refusesToJoinACallThatNothingKnows() async throws {
    let h = Harness()
    await #expect(throws: CallPreviewError.unknownCall) { try await h.previews.join(callID) }
    #expect(h.client.requests == [.join(callID)])
    #expect(h.client.joins.isEmpty)
  }

  @Test func passesOnTheClientsRefusal() async throws {
    let h = Harness()
    try await h.preview()
    h.client.requestError = .notAllowed(.ended(.endedRemotely))
    await #expect(throws: CallPreviewError.join(.notAllowed(.ended(.endedRemotely)))) {
      try await h.previews.join(callID)
    }
    #expect(h.client.joins.isEmpty)
  }

  @Test func needsAClient() async {
    let previews = CallPreviewActivities(center: FakeLiveActivityCenter())
    await #expect(throws: CallPreviewError.notAttached) { try await previews.join(callID) }
  }
}
