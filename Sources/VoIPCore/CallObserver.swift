/// Something that follows the client's calls from the moment it starts, such as an object that
/// shows each call preview as a Live Activity.
///
/// Pass observers to
/// ``VoIPClient/start(framework:media:push:audio:observers:configuration:clock:)``, which
/// attaches each one, in order, before it attaches the calling framework, the audio session and
/// the push source. So a stream from ``VoIPClient/events()`` that an observer creates in
/// ``attach(to:)`` receives every event, including those of the VoIP push that cold-launched the
/// app, which the system delivers as soon as the push source attaches. A stream that the app
/// creates after `start` returns begins then, and can miss them.
///
/// Subscribe in ``attach(to:)`` itself, not in a task that it starts, and read the stream in a
/// task:
///
/// ```swift
/// @MainActor
/// final class CallLog: CallObserver {
///   private(set) var lines: [String] = []
///   private var task: Task<Void, Never>?
///
///   func attach(to client: VoIPClient) {
///     let events = client.events()  // Subscribes before any push can arrive.
///     task = Task { [weak self] in
///       for await event in events { self?.lines.append("\(event)") }
///     }
///   }
/// }
///
/// let log = CallLog()
/// let client = try VoIPClient.start(
///   framework: LiveCommunicationKitAdapter(), media: AppMedia(), push: PushKitSource(),
///   observers: [log])
/// ```
///
/// The client keeps its observers for its life. An observer that keeps the client, for example to
/// request actions, keeps it weakly, so that the client can be released.
@MainActor
public protocol CallObserver: AnyObject {
  /// Starts following the client's calls.
  ///
  /// The client calls it once, while it starts, before it attaches the calling framework, the
  /// audio session and the push source, so the streams that the observer creates here see every
  /// event.
  ///
  /// - Parameter client: The client that is starting.
  func attach(to client: VoIPClient)
}
