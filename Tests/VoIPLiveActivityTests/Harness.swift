import Foundation
import Testing
import VoIPCore
import VoIPTesting

@testable import VoIPLiveActivity

/// A client whose call events the test sends, and which records the actions it is asked for.
///
/// A process runs one `VoIPClient` at a time, and the host's test suites run in parallel, so the
/// observer's tests script the client rather than start one.
@MainActor
final class ScriptedClient: CallPreviewClient {
  private let stream: AsyncStream<CallEvent>
  private let continuation: AsyncStream<CallEvent>.Continuation

  /// The actions the observer requested, in order.
  private(set) var requests: [Action] = []

  init() {
    (stream, continuation) = AsyncStream.makeStream(of: CallEvent.self)
  }

  /// Sends a call event, as the client does.
  func send(_ event: CallEvent) {
    continuation.yield(event)
  }

  func events() -> AsyncStream<CallEvent> {
    stream
  }

  func request(_ action: Action) async throws(ActionError) {
    requests.append(action)
  }
}

/// An observer on a fake center of Live Activities and a scripted client.
@MainActor
final class Harness {
  let center: FakeLiveActivityCenter
  let client = ScriptedClient()
  let previews: CallPreviewActivities
  private var iterator: AsyncStream<CallPreviewActivities.Event>.Iterator

  /// Creates the observer and attaches it to the client.
  ///
  /// - Parameters:
  ///   - options: How the observer shows call previews.
  ///   - center: The fake center, which may hold Live Activities from before the app ran.
  init(
    options: CallPreviewActivities.Options = CallPreviewActivities.Options(content: content),
    center: FakeLiveActivityCenter = FakeLiveActivityCenter()
  ) {
    self.center = center
    previews = CallPreviewActivities(options: options, center: center)
    iterator = previews.events().makeAsyncIterator()
    previews.attach(client)
  }

  /// The next event.
  func next() async throws -> CallPreviewActivities.Event {
    var iterator = self.iterator
    let event = await iterator.next(isolation: #isolation)
    self.iterator = iterator
    return try #require(event, "The event stream doesn't finish")
  }

  /// Sends a call event, as the client does.
  func send(_ event: CallEvent) {
    client.send(event)
  }

  /// Sends that a call became a call preview, and waits for its Live Activity.
  @discardableResult
  func preview(_ call: Call = filtered) async throws -> LiveActivityID {
    send(.previewStarted(call))
    #expect(try await next() == .started(call.id))
    return try #require(center.activities.first { $0.value.callID == call.id }?.key)
  }

  /// Expects that no event is waiting, by starting a preview that is known and reading it next.
  func expectNoEvents(sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let marker = Call(
      id: CallID(rawValue: "marker-\(UUID())"), isIncoming: true, parties: [alice],
      status: .previewing(.policy))
    try previews.start(marker)
    #expect(try await next() == .started(marker.id), sourceLocation: sourceLocation)
  }
}

/// A call filtered by Do Not Disturb, shown as a call preview.
let filtered = Call(
  id: callID, isIncoming: true, parties: [alice], status: .previewing(.filtered(.doNotDisturb)),
  metadata: ["room": "room-1"])

/// What the tests' previews show first, with a fixed start.
@Sendable func content(_ call: Call) -> CallPreviewAttributes.ContentState {
  var state = CallPreviewActivities.Options.defaultContent(for: call)
  state.startedAt = startedAt
  return state
}

/// The state that the tests' previews show first.
let firstState = CallPreviewAttributes.ContentState(
  status: .filtered, startedAt: startedAt, isJoinable: true)
