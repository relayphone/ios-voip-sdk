import Foundation
import Testing
import VoIPCore
import VoIPTesting

@testable import VoIPNotifications

let callID = CallID(rawValue: "call-1")
let otherCallID = CallID(rawValue: "call-2")
let dnd = PreviewReason.filtered(.doNotDisturb)

let alice: Party = {
  do {
    return try Party(
      handle: Handle(kind: .phoneNumber, value: "+14155550123"), displayName: "Alice")
  } catch {
    preconditionFailure("The fixture handle is valid: \(error)")
  }
}()

/// An incoming call from Alice.
func call(_ status: CallStatus, id: CallID = callID, hasVideo: Bool = false) -> Call {
  Call(id: id, isIncoming: true, parties: [alice], status: status, hasVideo: hasVideo)
}

/// The notification the notifier makes for Alice's call with the default options.
func notification(
  _ kind: CallNotification.Kind, _ id: CallID = callID, hasVideo: Bool = false
) -> CallNotification {
  CallNotification(callID: id, kind: kind, caller: alice, hasVideo: hasVideo)
}

/// A notifier that follows the call events the test sends, and posts to a fake center.
///
/// The notifier follows a stream rather than a client, so that each test sends exactly the call
/// events it needs, including ones a client sends only after a long path. `ClientTests` check the
/// notifier on a client.
@MainActor
final class Harness {
  let center = FakeCallNotificationCenter()
  let notifier: CallNotifier
  private let input: AsyncStream<CallEvent>.Continuation
  private var iterator: AsyncStream<CallNotifier.Event>.Iterator
  private var markers = 0

  /// The client to which the notifier routes the user's responses.
  let client = FakeClient()

  /// Whether the app is active, which a join waits for.
  let activity: FakeActivity

  /// The clock that times the wait for the app to become active.
  let clock = TestClock()

  /// Creates a notifier with the options, in an app that is active unless `isActive` is `false`.
  init(options: CallNotifier.Options = CallNotifier.Options(), isActive: Bool = true) {
    activity = FakeActivity(isActive: isActive)
    notifier = CallNotifier(options: options, center: center, activity: activity, clock: clock)
    let (events, input) = AsyncStream.makeStream(of: CallEvent.self)
    self.input = input
    iterator = notifier.events().makeAsyncIterator()
    notifier.follow(events, client: client)
  }

  /// Sends the notifier a call event, as the client does.
  func send(_ event: CallEvent) {
    input.yield(event)
  }

  /// The notifier's next event.
  func next() async throws -> CallNotifier.Event {
    var iterator = self.iterator
    let event = await iterator.next(isolation: #isolation)
    self.iterator = iterator
    return try #require(event, "The notifier's event stream doesn't finish")
  }

  /// Expects that the notifier did nothing more, by sending a call that it posts for and reading
  /// that call's notification next.
  ///
  /// - Parameter reason: The marker call's preview reason, which the options' triggers include.
  func expectNothingElse(
    marking reason: PreviewReason = dnd, sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    markers += 1
    let marker = CallID(rawValue: "marker-\(markers)")
    send(.previewStarted(call(.previewing(reason), id: marker)))
    let event = try await next()
    guard case .posted(let posted) = event else {
      Issue.record(
        "Expected the marker's notification, got \(event)", sourceLocation: sourceLocation)
      return
    }
    #expect(posted.callID == marker, sourceLocation: sourceLocation)
  }
}

/// A client whose calls the test sets, and which records the actions requested of it.
@MainActor
final class FakeClient: NotifierClient {
  var calls: [Call] = []
  private(set) var requests: [Action] = []
  /// The error with which the client refuses each request, or `nil` to accept it.
  var error: ActionError?

  func request(_ action: Action) async throws(ActionError) {
    requests.append(action)
    if let error { throw error }
  }
}

/// The app's activity, which the test sets.
@MainActor
final class FakeActivity: NotifierAppActivity {
  private(set) var isActive: Bool
  private var continuations: [AsyncStream<Void>.Continuation] = []

  init(isActive: Bool) {
    self.isActive = isActive
  }

  func activations() -> AsyncStream<Void> {
    let (activations, continuation) = AsyncStream.makeStream(of: Void.self)
    continuations.append(continuation)
    return activations
  }

  /// Makes the app active, as when it has come to the foreground.
  func becomeActive() {
    isActive = true
    for continuation in continuations { continuation.yield() }
  }
}
