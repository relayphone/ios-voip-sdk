import Testing
import VoIPCore
import VoIPNotifications
import VoIPTesting

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
    let notifier = CallNotifier(center: FakeCallNotificationCenter())
    var notices = notifier.events().makeAsyncIterator()
    let framework = FakeCallingFramework()
    await onVoIPActor { framework.presentationOutcome = .filtered(.doNotDisturb) }
    let client = try VoIPClient.start(
      framework: framework, media: FakeMedia(), observers: [notifier], clock: TestClock())
    var events = client.events().makeAsyncIterator()
    _ = await client.report(IncomingCall(id: callID, parties: [alice]))
    #expect(await notices.next(isolation: #isolation) == .posted(notification(.incoming)))
    #expect(await events.next(isolation: #isolation).map(\.isPreviewStarted) == true)

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
    #expect(try await notifier.handle(tap) == nil)
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

/// Runs a closure on `VoIPActor` in one job.
@VoIPActor
func onVoIPActor<Result: Sendable>(_ body: @VoIPActor () -> Result) -> Result {
  body()
}
