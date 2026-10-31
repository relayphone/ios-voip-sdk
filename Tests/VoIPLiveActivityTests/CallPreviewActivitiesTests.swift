import Foundation
import Testing
import VoIPCore
import VoIPTesting

@testable import VoIPLiveActivity

@MainActor
@Suite struct CallPreviewActivitiesTests {
  // MARK: Starting

  @Test func startsALiveActivityForACallPreviewInTheForeground() async throws {
    let h = Harness()
    let activity = try await h.preview()
    #expect(
      h.center.records == [
        .request(
          activity, CallPreviewAttributes(filtered), firstState, staleAfter: .seconds(120))
      ])
  }

  @Test(arguments: [
    PreviewReason.filtered(.blockList), .answeredElsewhere, .policy,
  ])
  func showsThePreviewsReason(_ reason: PreviewReason) async throws {
    let h = Harness()
    var call = filtered
    call.status = .previewing(reason)
    try await h.preview(call)
    guard case .request(_, _, let state, _) = h.center.records.first else {
      Issue.record("The observer started a Live Activity")
      return
    }
    #expect(state.status == CallPreviewStatus(call.status))
    #expect(state.isJoinable)
  }

  @Test func reportsThatItCannotStartInTheBackground() async throws {
    let h = Harness()
    h.center.isInForeground = false
    h.send(.previewStarted(filtered))
    #expect(try await h.next() == .startFailed(callID, .notInForeground))
    #expect(h.center.records.isEmpty)
  }

  @Test func reportsThatLiveActivitiesAreOff() async throws {
    let center = FakeLiveActivityCenter(
      authorization: LiveActivityAuthorization(
        areActivitiesEnabled: false, frequentPushesEnabled: false))
    let h = Harness(center: center)
    h.send(.previewStarted(filtered))
    #expect(try await h.next() == .startFailed(callID, .activitiesDisabled))
    #expect(h.center.records.isEmpty)
  }

  @Test func reportsWhatTheSystemRefuses() async throws {
    let h = Harness()
    h.center.requestError = .refused
    h.send(.previewStarted(filtered))
    #expect(try await h.next() == .startFailed(callID, .refused))
  }

  @Test func refusesAPreviewLargerThanTheSystemAllows() async throws {
    let h = Harness()
    var call = filtered
    call.metadata = ["notes": .string(String(repeating: "x", count: 4096))]
    h.send(.previewStarted(call))
    #expect(try await h.next() == .startFailed(callID, .tooLarge))
    #expect(throws: CallPreviewError.tooLarge) { try h.previews.start(call) }
    #expect(try await h.next() == .startFailed(callID, .tooLarge))
    #expect(h.center.records.isEmpty)
  }

  @Test func startsNothingWhenTheAppStartsPreviews() async throws {
    let h = Harness(options: CallPreviewActivities.Options(startsActivities: false))
    h.send(.previewStarted(filtered))
    try await h.expectNoEvents()
    #expect(!h.center.activities.values.contains { $0.callID == callID })
  }

  @Test func appStartsAPreviewWithItsOwnState() throws {
    let h = Harness()
    let call = Call(id: callID, isIncoming: true, parties: [alice], status: .ringing)
    let state = CallPreviewAttributes.ContentState(
      status: .policy, startedAt: startedAt, statusText: "Ringing on your iPad", isJoinable: false)
    try h.previews.start(call, state: state)
    #expect(h.center.records.map(\.state) == [state])
  }

  @Test func startsOneLiveActivityPerCall() async throws {
    let h = Harness()
    try await h.preview()
    // A join that fails returns the call to its preview.
    h.send(.previewStarted(filtered))
    try h.previews.start(filtered)
    try await h.expectNoEvents()
    #expect(h.center.records.count { $0.isRequest } == 2)  // The call's and the marker's.
  }

  @Test func followsAPreviewThatTheServersStarted() async throws {
    let h = Harness()
    let activity = h.center.startFromPush(CallPreviewAttributes(filtered), state: firstState)
    #expect(try await h.next() == .started(callID))
    // The client learns of the call later, in the foreground.
    h.send(.previewStarted(filtered))
    try await h.expectNoEvents()
    #expect(h.center.records.count { $0.isRequest } == 1)  // The marker's.
    await h.previews.end(callID)
    #expect(h.center.records.last == .end(activity, .ended(firstState), .immediate))
  }

  @Test func followsPreviewsThatRanBeforeTheAppStarted() async throws {
    let center = FakeLiveActivityCenter()
    let activity = center.startFromPush(CallPreviewAttributes(filtered), state: firstState)
    center.send(.pushTokenChanged(activity, Data([1])))
    let h = Harness(center: center)
    var tokens = h.previews.pushTokens().makeAsyncIterator()
    #expect(await tokens.next() == CallPreviewPushToken(callID: callID, token: Data([1])))
    try await h.previews.update(callID, firstState)
  }

  @Test func endsASecondLiveActivityForTheSameCall() async throws {
    let h = Harness()
    let first = try await h.preview()
    let second = h.center.startFromPush(CallPreviewAttributes(filtered), state: firstState)
    try await h.expectNoEvents()
    try await until { h.center.records.contains(.end(second, nil, .immediate)) }
    #expect(h.center.activities[first] != nil)
    #expect(h.center.activities[second] == nil)
  }

  // MARK: Ending

  @Test func endsAtOnceWhenThisDeviceJoins() async throws {
    let h = Harness()
    let activity = try await h.preview()
    var connecting = filtered
    connecting.status = .connecting
    h.send(.performed(.join(callID), connecting))
    #expect(try await h.next() == .ended(callID))
    #expect(h.center.records.last == .end(activity, nil, .immediate))
    #expect(h.center.activities.isEmpty)
  }

  @Test func showsTheFinalStateWhenTheCallEnds() async throws {
    let h = Harness()
    let activity = try await h.preview()
    var state = firstState
    state.statusText = "Your assistant is answering"
    state.snippet = "They asked whether you can call back after six."
    try await h.previews.update(callID, state)
    var ended = filtered
    ended.status = .ended(.endedRemotely)
    h.send(.ended(ended))
    #expect(try await h.next() == .ended(callID))
    let final = CallPreviewAttributes.ContentState(
      status: .ended, startedAt: startedAt,
      snippet: "They asked whether you can call back after six.", isJoinable: false)
    #expect(h.center.records.last == .end(activity, final, .after(.seconds(120))))
  }

  @Test func keepsTheFinalStateForTheConfiguredTime() async throws {
    let h = Harness(
      options: CallPreviewActivities.Options(endedDismissal: .seconds(30), content: content))
    let activity = try await h.preview()
    var ended = filtered
    ended.status = .ended(.answeredElsewhere)
    h.send(.ended(ended))
    #expect(try await h.next() == .ended(callID))
    #expect(h.center.records.last == .end(activity, .ended(firstState), .after(.seconds(30))))
  }

  @Test func ignoresCallsWithoutAPreview() async throws {
    let h = Harness()
    var ended = filtered
    ended.status = .ended(.endedHere)
    h.send(.performed(.join(callID), filtered))
    h.send(.ended(ended))
    try await h.expectNoEvents()
    #expect(h.center.records.count == 1)  // The marker's.
  }

  @Test func reportsAPreviewThatTheSystemOrTheServersEnded() async throws {
    let h = Harness()
    let activity = try await h.preview()
    var tokens = h.previews.pushTokens().makeAsyncIterator()
    h.center.send(.ended(activity))
    #expect(try await h.next() == .ended(callID))
    #expect(await tokens.next() == CallPreviewPushToken(callID: callID, token: nil))
    await #expect(throws: CallPreviewError.notStarted) {
      try await h.previews.update(callID, firstState)
    }
  }

  @Test func appEndsAPreview() async throws {
    let h = Harness()
    let activity = try await h.preview()
    await h.previews.end(callID, dismissal: .after(.seconds(5)))
    #expect(try await h.next() == .ended(callID))
    #expect(h.center.records.last == .end(activity, .ended(firstState), .after(.seconds(5))))
    #expect(h.client.requests.isEmpty)
  }

  // MARK: Updating

  @Test func updatesWithAFreshStaleDate() async throws {
    let h = Harness(
      options: CallPreviewActivities.Options(staleAfter: .seconds(45), content: content))
    let activity = try await h.preview()
    var state = firstState
    state.snippet = "Hello"
    try await h.previews.update(callID, state)
    #expect(h.center.records.last == .update(activity, state, staleAfter: .seconds(45)))
  }

  @Test func refusesToUpdateWhatDidNotStartOrDoesNotFit() async throws {
    let h = Harness()
    await #expect(throws: CallPreviewError.notStarted) {
      try await h.previews.update(callID, firstState)
    }
    try await h.preview()
    var state = firstState
    state.statusText = String(repeating: "x", count: 4096)
    await #expect(throws: CallPreviewError.tooLarge) {
      try await h.previews.update(callID, state)
    }
  }

  // MARK: Tokens and authorization

  @Test func streamsEachPreviewsPushToken() async throws {
    let h = Harness()
    var tokens = h.previews.pushTokens().makeAsyncIterator()
    let activity = try await h.preview()
    h.center.send(.pushTokenChanged(activity, Data([1])))
    h.center.send(.pushTokenChanged(activity, Data([2])))
    #expect(await tokens.next() == CallPreviewPushToken(callID: callID, token: Data([1])))
    #expect(await tokens.next() == CallPreviewPushToken(callID: callID, token: Data([2])))

    var later = h.previews.pushTokens().makeAsyncIterator()
    #expect(await later.next() == CallPreviewPushToken(callID: callID, token: Data([2])))

    h.send(.performed(.join(callID), filtered))
    #expect(await tokens.next() == CallPreviewPushToken(callID: callID, token: nil))
  }

  @Test func ignoresTokensOfLiveActivitiesItDoesNotFollow() async throws {
    let h = Harness()
    var tokens = h.previews.pushTokens().makeAsyncIterator()
    h.center.send(.pushTokenChanged(LiveActivityID(rawValue: "unknown"), Data([9])))
    let activity = try await h.preview()
    h.center.send(.pushTokenChanged(activity, Data([1])))
    #expect(await tokens.next() == CallPreviewPushToken(callID: callID, token: Data([1])))
  }

  @Test func streamsThePushToStartToken() async throws {
    let center = FakeLiveActivityCenter()
    center.send(.pushToStartTokenChanged(Data([1])))
    let h = Harness(center: center)
    var tokens = h.previews.pushToStartTokens().makeAsyncIterator()
    #expect(await tokens.next() == Data([1]))
    center.send(.pushToStartTokenChanged(Data([2])))
    #expect(await tokens.next() == Data([2]))
  }

  @Test func followsTheUsersAuthorization() async throws {
    let h = Harness()
    let allowed = LiveActivityAuthorization(areActivitiesEnabled: true, frequentPushesEnabled: true)
    let off = LiveActivityAuthorization(areActivitiesEnabled: false, frequentPushesEnabled: true)
    #expect(h.previews.authorization == allowed)
    var updates = h.previews.authorizationUpdates().makeAsyncIterator()
    #expect(await updates.next() == allowed)
    h.center.send(.authorizationChanged(off))
    #expect(await updates.next() == off)
    #expect(h.previews.authorization == off)

    h.send(.previewStarted(filtered))
    #expect(try await h.next() == .startFailed(callID, .activitiesDisabled))
  }

  // MARK: Options

  @Test(arguments: [
    (CallStatus.previewing(.filtered(.doNotDisturb)), CallPreviewStatus.filtered),
    (.previewing(.answeredElsewhere), .answeredElsewhere), (.previewing(.policy), .policy),
    (.ringing, .policy), (.ended(.endedHere), .ended),
  ])
  func defaultContentFollowsTheCall(_ status: CallStatus, _ expected: CallPreviewStatus) {
    var call = filtered
    call.status = status
    let before = Date.now
    let state = CallPreviewActivities.Options.defaultContent(for: call)
    #expect(state.status == expected)
    #expect(state.startedAt >= before && state.startedAt <= .now)
    #expect(state.statusText == nil)
    #expect(state.snippet == nil)
    #expect(state.isJoinable)
  }

  @Test func defaultOptions() {
    let options = CallPreviewActivities.Options()
    #expect(options.startsActivities)
    #expect(options.staleAfter == .seconds(120))
    #expect(options.endedDismissal == .seconds(120))
  }
}

extension CallPreviewAttributes.ContentState {
  /// The final state that the observer shows once a call ended.
  static func ended(_ state: Self) -> Self {
    Self(status: .ended, startedAt: state.startedAt, snippet: state.snippet, isJoinable: false)
  }
}

extension FakeLiveActivityCenter.Record {
  var isRequest: Bool {
    if case .request = self { true } else { false }
  }

  var state: CallPreviewAttributes.ContentState? {
    switch self {
    case .request(_, _, let state, _), .update(_, let state, _): state
    case .end(_, let state, _): state
    }
  }
}

/// Waits until a condition holds, while the observer's tasks run.
@MainActor
func until(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation)
  async throws
{
  for _ in 0..<1000 {
    if condition() { return }
    await Task.yield()
  }
  Issue.record("The condition never held", sourceLocation: sourceLocation)
}
