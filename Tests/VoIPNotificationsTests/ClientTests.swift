import Observation
import Testing
import VoIPCore
import VoIPTesting

@testable import VoIPNotifications

/// The notifier as an observer of a client running on the fakes. They run one at a time because a
/// process runs at most one client.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct ClientTests {
  /// The VoIP push that cold-launched the app arrives as soon as the client attaches the push
  /// source, and the system filters its call.
  @Test func coldLaunchFilteredCallGetsANotificationThenAMissedCallOne() async throws {
    let center = FakeCallNotificationCenter()
    let notifier = CallNotifier(center: center)
    var notices = notifier.events().makeAsyncIterator()
    let framework = FakeCallingFramework()
    await onVoIPActor { framework.presentationOutcome = .filtered(.doNotDisturb) }
    let push = FakePushSource(pending: [
      .incoming(IncomingCall(id: callID, parties: [alice]), eventID: EventID(rawValue: "e1"))
    ])
    let client = try VoIPClient.start(
      framework: framework, media: FakeMedia(), push: push, observers: [notifier],
      clock: TestClock())

    #expect(await notices.next(isolation: #isolation) == .posted(notification(.incoming)))
    await client.receive(.endedRemotely, for: callID, eventID: EventID(rawValue: "e2"))
    #expect(await notices.next(isolation: #isolation) == .posted(notification(.missed)))
    #expect(center.delivered == [notification(.missed)])
  }

  @Test func joiningAFilteredCallWithdrawsItsNotification() async throws {
    let center = FakeCallNotificationCenter()
    let notifier = CallNotifier(center: center)
    var notices = notifier.events().makeAsyncIterator()
    let framework = FakeCallingFramework()
    await onVoIPActor { framework.presentationOutcome = .filtered(.doNotDisturb) }
    let client = try VoIPClient.start(
      framework: framework, media: FakeMedia(), observers: [notifier], clock: TestClock())
    var events = client.events().makeAsyncIterator()

    #expect(
      await client.report(IncomingCall(id: callID, parties: [alice]))
        == .previewed(.filtered(.doNotDisturb)))
    #expect(await notices.next(isolation: #isolation) == .posted(notification(.incoming)))
    try await client.request(.join(callID))
    while let event = await events.next(isolation: #isolation) {
      if case .joinRequested = event { break }
    }
    await client.confirmPlaced(callID)
    #expect(await notices.next(isolation: #isolation) == .withdrawn(callID))
    #expect(center.delivered.isEmpty)
  }

  @Test func tapOnAFilteredCallsNotificationJoinsItThroughTheClient() async throws {
    // The tests don't run in an app whose state the notifier could wait for.
    let notifier = CallNotifier(
      center: FakeCallNotificationCenter(), activity: FakeActivity(isActive: true),
      clock: TestClock())
    var notices = notifier.events().makeAsyncIterator()
    let framework = FakeCallingFramework()
    await onVoIPActor { framework.presentationOutcome = .filtered(.doNotDisturb) }
    let client = try VoIPClient.start(
      framework: framework, media: FakeMedia(), observers: [notifier], clock: TestClock())
    var events = client.events().makeAsyncIterator()
    _ = await client.report(IncomingCall(id: callID, parties: [alice]))
    #expect(await notices.next(isolation: #isolation) == .posted(notification(.incoming)))
    #expect(await events.next(isolation: #isolation).map(\.isPreviewStarted) == true)
    // The notifier routes a tap by the client's calls.
    await until(client) { client in
      client.calls.first { $0.id == callID }?.status == .previewing(dnd)
    }

    let tap = CallNotificationResponse(callID: callID, caller: alice, action: .open)
    #expect(try await notifier.handle(tap) == .joining(callID))
    guard case .joinRequested(let call)? = await events.next(isolation: #isolation) else {
      Issue.record("The client didn't ask the app to place the join")
      return
    }
    #expect(call.id == callID)

    // Once the call is joined, the user can't join it again from the notification.
    await client.confirmPlaced(callID)
    #expect(await notices.next(isolation: #isolation) == .withdrawn(callID))
    await until(client) { client in client.calls.first { $0.id == callID }?.status == .connecting }
    #expect(try await notifier.handle(tap) == nil)
  }

  /// Joining a call that the client didn't know, such as from a call preview that the app's
  /// servers started, posts nothing: the user started the join.
  @Test(arguments: [false, true])
  func joiningAnUnknownCallPostsNothing(callEnded: Bool) async throws {
    let center = FakeCallNotificationCenter()
    let notifier = CallNotifier(
      options: CallNotifier.Options(triggers: [.filtered, .previewedByPolicy]), center: center)
    var notices = notifier.events().makeAsyncIterator()
    let framework = FakeCallingFramework()
    let client = try VoIPClient.start(
      framework: framework, media: FakeMedia(), observers: [notifier], clock: TestClock())
    var events = client.events().makeAsyncIterator()
    let joined = IncomingCall(
      id: callID, parties: [alice], presentationPolicy: PresentationPolicy(incoming: .preview))

    if callEnded {
      await client.receive(.endedRemotely, for: callID, eventID: EventID(rawValue: "e1"))
      await #expect(throws: ActionError.notAllowed(.ended(.endedRemotely))) {
        try await client.join(joined)
      }
    } else {
      try await client.join(joined)
      while let event = await events.next(isolation: #isolation) {
        if case .joinRequested = event { break }
      }
      await client.confirmPlaced(callID)
    }
    // A call that the policy previews afterwards is the first that the notifier posts for.
    _ = await client.report(
      IncomingCall(
        id: otherCallID, parties: [alice],
        presentationPolicy: PresentationPolicy(incoming: .preview)))
    #expect(
      await notices.next(isolation: #isolation) == .posted(notification(.incoming, otherCallID)))
    #expect(center.records == [.post(notification(.incoming, otherCallID))])
  }

  /// The user tried to join a call from its notification or its call preview, and the system
  /// refused: the call returns to its preview, then ends, without another notification.
  @Test(arguments: [false, true])
  func aRefusedJoinPostsNothingMore(knownCall: Bool) async throws {
    let center = FakeCallNotificationCenter()
    let notifier = CallNotifier(
      options: CallNotifier.Options(triggers: [.filtered, .previewedByPolicy]), center: center)
    var notices = notifier.events().makeAsyncIterator()
    let framework = FakeCallingFramework()
    await onVoIPActor { framework.requestResult = .refuse(.unknownCall) }
    let client = try VoIPClient.start(
      framework: framework, media: FakeMedia(), observers: [notifier], clock: TestClock())
    let previewed = IncomingCall(
      id: callID, parties: [alice], presentationPolicy: PresentationPolicy(incoming: .preview))

    if knownCall {
      // A tap on the call's notification.
      _ = await client.report(previewed)
      #expect(await notices.next(isolation: #isolation) == .posted(notification(.incoming)))
      await #expect(throws: ActionError.self) { try await client.request(.join(callID)) }
      #expect(await notices.next(isolation: #isolation) == .withdrawn(callID))
    } else {
      // Join on a call preview that the app's servers started.
      await #expect(throws: ActionError.self) { try await client.join(previewed) }
    }
    await client.receive(.endedRemotely, for: callID, eventID: EventID(rawValue: "e1"))
    // A call that the policy previews afterwards is the next that the notifier posts for.
    _ = await client.report(
      IncomingCall(
        id: otherCallID, parties: [alice],
        presentationPolicy: PresentationPolicy(incoming: .preview)))
    #expect(
      await notices.next(isolation: #isolation) == .posted(notification(.incoming, otherCallID)))
    let before: [FakeCallNotificationCenter.Record] =
      knownCall ? [.post(notification(.incoming)), .withdraw(callID)] : []
    #expect(center.records == before + [.post(notification(.incoming, otherCallID))])
  }

  @Test func ringingCallGetsNoNotification() async throws {
    let center = FakeCallNotificationCenter()
    let notifier = CallNotifier(center: center)
    var notices = notifier.events().makeAsyncIterator()
    let framework = FakeCallingFramework()
    let client = try VoIPClient.start(
      framework: framework, media: FakeMedia(), observers: [notifier], clock: TestClock())

    #expect(await client.report(IncomingCall(id: callID, parties: [alice])) == .presented)
    await client.receive(.endedRemotely, for: callID, eventID: EventID(rawValue: "e1"))
    // A filtered call afterwards is the first that the notifier posts for.
    await onVoIPActor { framework.presentationOutcome = .filtered(.doNotDisturb) }
    _ = await client.report(IncomingCall(id: otherCallID, parties: [alice]))
    #expect(
      await notices.next(isolation: #isolation) == .posted(notification(.incoming, otherCallID)))
    #expect(center.records == [.post(notification(.incoming, otherCallID))])
  }
}

extension CallEvent {
  var isPreviewStarted: Bool {
    if case .previewStarted = self { true } else { false }
  }
}

/// Waits until the client's observable state satisfies a condition.
///
/// The client applies the engine's state in a task of its own, which may not have run when a test
/// reads an event, so a test waits with this before it reads ``VoIPClient/calls``.
@MainActor
func until(
  _ client: VoIPClient, _ condition: @escaping @MainActor @Sendable (VoIPClient) -> Bool
) async {
  let observations = Observations { @MainActor [weak client] in client.map(condition) ?? true }
  for await satisfied in observations where satisfied { return }
}

/// Runs a closure on `VoIPActor` in one job.
@VoIPActor
func onVoIPActor<Result: Sendable>(_ body: @VoIPActor () -> Result) -> Result {
  body()
}
