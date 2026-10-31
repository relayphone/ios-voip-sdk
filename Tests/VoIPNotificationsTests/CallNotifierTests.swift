import Testing
import VoIPCore
import VoIPTesting

@testable import VoIPNotifications

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CallNotifierTests {
  // MARK: When it posts

  @Test(arguments: [false, true])
  func filteredCallPreviewPostsAnIncomingCallNotification(hasVideo: Bool) async throws {
    let h = Harness()
    h.send(.previewStarted(call(.previewing(dnd), hasVideo: hasVideo)))
    let expected = notification(.incoming, hasVideo: hasVideo)
    #expect(try await h.next() == .posted(expected))
    #expect(expected.body == (hasVideo ? "Incoming video call" : "Incoming call"))
    #expect(expected.interruptionLevel == .active)
    #expect(expected.playsSound)
    #expect(h.center.delivered == [expected])
  }

  @Test func postsOncePerCallWhenAFailedJoinReturnsToThePreview() async throws {
    let h = Harness(options: CallNotifier.Options(withdrawsWhenJoined: false))
    h.send(.previewStarted(call(.previewing(dnd))))
    #expect(try await h.next() == .posted(notification(.incoming)))
    h.send(.joinRequested(call(.previewing(dnd))))
    h.send(.previewStarted(call(.previewing(dnd))))
    try await h.expectNothingElse()
    #expect(h.center.records.filter { $0 == .post(notification(.incoming)) }.count == 1)
  }

  @Test(arguments: [
    CallEvent.presented(call(.ringing)),
    .previewStarted(call(.previewing(.filtered(.blockList)))),
    .previewStarted(call(.previewing(.filtered(.unspecified)))),
    .previewStarted(call(.previewing(.answeredElsewhere))),
    .previewStarted(call(.previewing(.policy))),
    .ended(call(.ended(.filtered(.blockList)))),
    .ended(call(.ended(.filtered(.unspecified)))),
    .ended(call(.ended(.unanswered))),
    .ended(call(.ended(.answeredElsewhere))),
    .performed(.join(callID), call(.connecting)),
  ])
  func postsNothingForOtherCalls(_ event: CallEvent) async throws {
    let h = Harness()
    h.send(event)
    try await h.expectNothingElse()
    #expect(h.center.records.count == 1)
  }

  @Test func postsForCallsPreviewedByPolicyWhenAsked() async throws {
    let h = Harness(options: CallNotifier.Options(triggers: [.filtered, .previewedByPolicy]))
    h.send(.previewStarted(call(.previewing(.policy))))
    #expect(try await h.next() == .posted(notification(.incoming)))
    h.send(.previewStarted(call(.previewing(dnd), id: otherCallID)))
    #expect(try await h.next() == .posted(notification(.incoming, otherCallID)))
  }

  @Test func postsNothingForFilteredCallsWithoutTheirTrigger() async throws {
    let h = Harness(options: CallNotifier.Options(triggers: .previewedByPolicy))
    h.send(.previewStarted(call(.previewing(dnd))))
    h.send(.ended(call(.ended(.filtered(.doNotDisturb)), id: otherCallID)))
    try await h.expectNothingElse(marking: .policy)
    #expect(h.center.records.count == 1)
  }

  @Test func postsNothingForACallWithoutParties() async throws {
    let h = Harness()
    let call = Call(id: callID, isIncoming: true, parties: [], status: .previewing(dnd))
    h.send(.previewStarted(call))
    try await h.expectNothingElse()
  }

  // MARK: After it posts

  @Test(arguments: [false, true])
  func callThatEndsWithoutBeingJoinedGetsAMissedCallNotification(hasVideo: Bool) async throws {
    let h = Harness()
    h.send(.previewStarted(call(.previewing(dnd), hasVideo: hasVideo)))
    #expect(try await h.next() == .posted(notification(.incoming, hasVideo: hasVideo)))

    h.send(.ended(call(.ended(.endedRemotely), hasVideo: hasVideo)))
    let missed = notification(.missed, hasVideo: hasVideo)
    #expect(try await h.next() == .posted(missed))
    #expect(missed.body == (hasVideo ? "Missed video call" : "Missed call"))
    #expect(
      h.center.records == [.post(notification(.incoming, hasVideo: hasVideo)), .post(missed)])
    #expect(h.center.delivered == [missed])
  }

  @Test func endedWithoutJoiningCanKeepTheNotification() async throws {
    let h = Harness(options: CallNotifier.Options(endedWithoutJoining: { _ in .keep }))
    h.send(.previewStarted(call(.previewing(dnd))))
    #expect(try await h.next() == .posted(notification(.incoming)))
    h.send(.ended(call(.ended(.endedRemotely))))
    try await h.expectNothingElse()
    #expect(h.center.delivered.first == notification(.incoming))
  }

  @Test func endedWithoutJoiningCanRemoveTheNotification() async throws {
    let h = Harness(options: CallNotifier.Options(endedWithoutJoining: { _ in .remove }))
    h.send(.previewStarted(call(.previewing(dnd))))
    #expect(try await h.next() == .posted(notification(.incoming)))
    h.send(.ended(call(.ended(.endedRemotely))))
    #expect(try await h.next() == .withdrawn(callID))
    #expect(h.center.delivered.isEmpty)
  }

  @Test func endedWithoutJoiningReceivesTheEndedCall() async throws {
    let ended = Recorded<Call>()
    let h = Harness(
      options: CallNotifier.Options(endedWithoutJoining: {
        ended.values.append($0)
        return .remove
      }))
    h.send(.previewStarted(call(.previewing(dnd))))
    #expect(try await h.next() == .posted(notification(.incoming)))
    h.send(.ended(call(.ended(.declinedElsewhere))))
    #expect(try await h.next() == .withdrawn(callID))
    #expect(ended.values == [call(.ended(.declinedElsewhere))])
  }

  @Test func joiningWithdrawsTheNotificationAndEndingThenDoesNothing() async throws {
    let h = Harness()
    h.send(.previewStarted(call(.previewing(dnd))))
    #expect(try await h.next() == .posted(notification(.incoming)))
    h.send(.joinRequested(call(.previewing(dnd))))
    h.send(.performed(.join(callID), call(.connecting)))
    #expect(try await h.next() == .withdrawn(callID))
    h.send(.ended(call(.ended(.endedHere))))
    try await h.expectNothingElse()
    #expect(h.center.records.prefix(2) == [.post(notification(.incoming)), .withdraw(callID)])
  }

  @Test func joiningCanKeepTheNotification() async throws {
    let h = Harness(options: CallNotifier.Options(withdrawsWhenJoined: false))
    h.send(.previewStarted(call(.previewing(dnd))))
    #expect(try await h.next() == .posted(notification(.incoming)))
    h.send(.performed(.join(callID), call(.connecting)))
    h.send(.ended(call(.ended(.endedRemotely))))
    try await h.expectNothingElse()
    #expect(h.center.delivered.first == notification(.incoming))
  }

  /// When the presentation policy doesn't preview filtered calls, a filtered call ends at once.
  @Test(arguments: [
    (CallNotifier.EndedCallNotification.missedCall, CallNotification.Kind?.some(.missed)),
    (.keep, .incoming), (.remove, nil),
  ])
  func filteredCallThatEndsAtOncePostsWhatItsNotificationBecomes(
    _ ending: CallNotifier.EndedCallNotification, _ kind: CallNotification.Kind?
  ) async throws {
    let h = Harness(options: CallNotifier.Options(endedWithoutJoining: { _ in ending }))
    h.send(.ended(call(.ended(.filtered(.doNotDisturb)))))
    if let kind {
      #expect(try await h.next() == .posted(notification(kind)))
    }
    try await h.expectNothingElse()
    #expect(h.center.records.count == (kind == nil ? 1 : 2))
  }

  // MARK: Making notifications

  @Test func optionsSetTheInterruptionLevelAndSound() async throws {
    let h = Harness(options: CallNotifier.Options(interruptionLevel: .passive, playsSound: false))
    h.send(.previewStarted(call(.previewing(dnd))))
    let expected = CallNotification(
      callID: callID, kind: .incoming, caller: alice, interruptionLevel: .passive,
      playsSound: false)
    #expect(try await h.next() == .posted(expected))
  }

  @Test func customizeChangesEachNotification() async throws {
    let h = Harness(
      options: CallNotifier.Options(customize: { notification, call in
        var notification = notification
        notification.body = notification.kind == .incoming ? "Appel entrant" : "Appel manqué"
        notification.caller.displayName = "Alice (\(call.id.rawValue))"
        return notification
      }))
    h.send(.previewStarted(call(.previewing(dnd))))
    var incoming = notification(.incoming)
    incoming.body = "Appel entrant"
    incoming.caller.displayName = "Alice (call-1)"
    #expect(try await h.next() == .posted(incoming))

    h.send(.ended(call(.ended(.endedRemotely))))
    var missed = notification(.missed)
    missed.body = "Appel manqué"
    missed.caller.displayName = "Alice (call-1)"
    #expect(try await h.next() == .posted(missed))
  }

  @Test func customizeCanPostNothing() async throws {
    let h = Harness(
      options: CallNotifier.Options(customize: { notification, _ in
        notification.callID == callID ? nil : notification
      }))
    h.send(.previewStarted(call(.previewing(dnd))))
    h.send(.ended(call(.ended(.endedRemotely))))
    try await h.expectNothingElse()
    #expect(h.center.records.count == 1)
  }

  // MARK: Failures

  @Test func reportsAPostTheCenterRefuses() async throws {
    let h = Harness()
    h.center.postError = .notAuthorized
    h.send(.previewStarted(call(.previewing(dnd))))
    #expect(try await h.next() == .failed(notification(.incoming), .notAuthorized))
    // The missed-call notification is still tried, in case the user allowed notifications since.
    h.send(.ended(call(.ended(.endedRemotely))))
    #expect(try await h.next() == .failed(notification(.missed), .notAuthorized))
    #expect(h.center.delivered.isEmpty)
  }

  @Test func removesNothingThatItDidNotPost() async throws {
    let h = Harness(options: CallNotifier.Options(endedWithoutJoining: { _ in .remove }))
    h.center.postError = .postFailed
    h.send(.previewStarted(call(.previewing(dnd))))
    #expect(try await h.next() == .failed(notification(.incoming), .postFailed))
    h.send(.ended(call(.ended(.endedRemotely))))
    h.center.postError = nil
    try await h.expectNothingElse()
    #expect(!h.center.records.contains(.withdraw(callID)))
  }

  // MARK: Events

  @Test func followsOnlyTheClientItWasLastAttachedTo() async throws {
    let h = Harness()
    let (next, input) = AsyncStream.makeStream(of: CallEvent.self)
    h.notifier.follow(next)
    h.send(.previewStarted(call(.previewing(dnd))))
    input.yield(.previewStarted(call(.previewing(dnd), id: otherCallID)))
    #expect(try await h.next() == .posted(notification(.incoming, otherCallID)))
    #expect(h.center.records == [.post(notification(.incoming, otherCallID))])
  }

  @Test func eachEventStreamReceivesEveryEvent() async throws {
    let h = Harness()
    var other = h.notifier.events().makeAsyncIterator()
    h.send(.previewStarted(call(.previewing(dnd))))
    #expect(try await h.next() == .posted(notification(.incoming)))
    #expect(await other.next(isolation: #isolation) == .posted(notification(.incoming)))
  }
}

/// Values that a closure records on the main actor.
@MainActor
final class Recorded<Value> {
  var values: [Value] = []
}
