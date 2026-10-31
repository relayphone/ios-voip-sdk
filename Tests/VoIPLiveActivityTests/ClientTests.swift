import Foundation
import Testing
import VoIPCore
import VoIPTesting

@testable import VoIPLiveActivity

/// The observer on a running `VoIPClient`, with the SDK's fakes. They run one at a time, because a
/// process runs one client at a time; no other suite in this target starts one.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ClientTests {
  /// A client with the observer, on the fakes and a test clock.
  @MainActor
  final class App {
    let framework = FakeCallingFramework()
    let center: FakeLiveActivityCenter
    let previews: CallPreviewActivities
    let client: VoIPClient
    private var callEvents: AsyncStream<CallEvent>.Iterator
    private var previewEvents: AsyncStream<CallPreviewActivities.Event>.Iterator

    init(
      center: FakeLiveActivityCenter = FakeLiveActivityCenter(),
      outcome: PresentationOutcome = .presented, pending: [VoIPPush] = []
    ) async throws {
      self.center = center
      await Self.present(with: outcome, framework)
      previews = CallPreviewActivities(
        options: CallPreviewActivities.Options(content: content), center: center)
      previewEvents = previews.events().makeAsyncIterator()
      client = try VoIPClient.start(
        framework: framework, media: FakeMedia(), push: FakePushSource(pending: pending),
        observers: [previews], clock: TestClock())
      callEvents = client.events().makeAsyncIterator()
    }

    /// Makes the calling framework present each call as the test says.
    @VoIPActor
    private static func present(
      with outcome: PresentationOutcome, _ framework: FakeCallingFramework
    ) {
      framework.presentationOutcome = outcome
    }

    /// Waits for the client's next event of a kind, skipping others.
    func nextCallEvent(where matches: (CallEvent) -> Bool) async throws -> CallEvent {
      var iterator = callEvents
      defer { callEvents = iterator }
      while let event = await iterator.next(isolation: #isolation) {
        if matches(event) { return event }
      }
      throw CancellationError()
    }

    /// The observer's next event.
    func nextPreviewEvent() async throws -> CallPreviewActivities.Event {
      var iterator = previewEvents
      let event = await iterator.next(isolation: #isolation)
      previewEvents = iterator
      return try #require(event)
    }

    /// Joins the call as the Join button does, and places the join as the app does.
    func joinAndPlace(_ id: CallID) async throws {
      try await previews.join(id)
      _ = try await nextCallEvent { if case .joinRequested = $0 { true } else { false } }
      await client.confirmPlaced(id)
      let performed = try await nextCallEvent {
        if case .performed(.join, _) = $0 { true } else { false }
      }
      guard case .performed(_, let call) = performed else { return }
      #expect(call.status == .connecting)
    }
  }

  @Test func filteredCallOfAColdLaunchGetsALiveActivity() async throws {
    let push = IncomingCall(id: callID, parties: [alice], metadata: ["room": "room-1"])
    let app = try await App(
      outcome: .filtered(.doNotDisturb), pending: [.incoming(push, eventID: EventID(rawValue: "e"))]
    )
    #expect(try await app.nextPreviewEvent() == .started(callID))
    guard case .request(_, let attributes, let state, let staleAfter)? = app.center.records.first
    else {
      Issue.record("The observer started a Live Activity")
      return
    }
    #expect(attributes == CallPreviewAttributes(filtered))
    #expect(state == firstState)
    #expect(staleAfter == .seconds(120))
  }

  @Test func joiningAPreviewEndsItsLiveActivity() async throws {
    let app = try await App()
    _ = await app.client.report(
      IncomingCall(
        id: callID, parties: [alice], presentationPolicy: PresentationPolicy(incoming: .preview)))
    #expect(try await app.nextPreviewEvent() == .started(callID))
    let activity = try #require(app.center.activities.keys.first)

    try await app.joinAndPlace(callID)
    #expect(try await app.nextPreviewEvent() == .ended(callID))
    #expect(app.center.records.last == .end(activity, nil, .immediate))
    #expect(app.center.activities.isEmpty)
  }

  @Test func joiningAPreviewThatTheServersStartedReportsItsCall() async throws {
    let center = FakeLiveActivityCenter()
    let activity = center.startFromPush(CallPreviewAttributes(filtered), state: firstState)
    let app = try await App(center: center)
    try await app.joinAndPlace(callID)
    let call = try #require(app.client.calls.first { $0.id == callID })
    #expect(call.parties == [alice])
    #expect(call.metadata == ["room": "room-1"])
    #expect(try await app.nextPreviewEvent() == .ended(callID))
    #expect(center.records == [.end(activity, nil, .immediate)])

    // The joined call is the app's: it outlives its preview.
    try await app.client.request(.end(callID))
    _ = try await app.nextCallEvent { if case .ended = $0 { true } else { false } }
  }

  @Test func callThatEndsElsewhereLeavesItsFinalState() async throws {
    let app = try await App()
    _ = await app.client.report(
      IncomingCall(
        id: callID, parties: [alice], presentationPolicy: PresentationPolicy(incoming: .preview)))
    #expect(try await app.nextPreviewEvent() == .started(callID))
    let activity = try #require(app.center.activities.keys.first)

    await app.client.receive(.endedRemotely, for: callID, eventID: EventID(rawValue: "end"))
    #expect(try await app.nextPreviewEvent() == .ended(callID))
    var started = firstState
    started.status = .policy
    #expect(app.center.records.last == .end(activity, .ended(started), .after(.seconds(120))))
  }
}
