public import Observation
import Synchronization

/// The app's entry point to the SDK: it presents and controls the app's calls, and tells the app
/// what happens to them.
///
/// Start one client when the app launches, with the calling framework adapter that the app links,
/// the app's media and, usually, the PushKit adapter. The SDK keeps the state of every call by its
/// ``CallID`` and performs the user's actions itself, then tells the app through ``events()``.
/// Read ``calls`` and ``isAudioActive`` from SwiftUI or with Observation.
///
/// Code that must see every event from the moment the client starts, including those of the VoIP
/// push that cold-launched the app, is a ``CallObserver`` passed to
/// ``start(framework:media:push:audio:observers:configuration:clock:)``.
@MainActor
@Observable
public final class VoIPClient {
  /// The calls on this device that haven't ended, in the order they began, including call
  /// previews.
  public private(set) var calls: [Call] = []

  /// Whether the system activated the audio session for calls.
  public private(set) var isAudioActive = false

  let engine: CallEngine
  private let subscribers: Subscribers
  /// The observers that follow calls, which the client keeps for its life.
  private let observers: [any CallObserver]
  @ObservationIgnored private var revision: UInt64 = 0

  /// Whether a client is running in this process.
  private nonisolated static let isRunning = Mutex(false)

  private init(
    engine: CallEngine, subscribers: Subscribers, observers: [any CallObserver],
    snapshots: AsyncStream<Snapshot>
  ) {
    self.engine = engine
    self.subscribers = subscribers
    self.observers = observers
    Task { [weak self] in
      for await snapshot in snapshots { self?.apply(snapshot) }
    }
  }

  deinit {
    Self.isRunning.withLock { $0 = false }
  }

  /// Starts the SDK.
  ///
  /// A process has one calling framework provider, so it runs at most one client. Keep the client
  /// for the life of the app; another can start only after it is released.
  ///
  /// - Parameters:
  ///   - framework: The calling framework adapter that presents calls.
  ///   - media: The app's real-time audio and video transport.
  ///   - push: The source of the app's VoIP pushes, usually the PushKit adapter.
  ///   - audio: The app's audio session, usually `AudioSessionAdapter`, which the SDK configures
  ///     for each call and watches for interruptions. Without one, the app configures
  ///     `AVAudioSession` for calls itself.
  ///   - observers: Objects that follow calls from the moment the client starts. The client
  ///     attaches each one, in order, before it attaches the calling framework, the audio session
  ///     and the push source, and keeps them for its life.
  ///   - configuration: How the SDK presents and controls calls.
  ///   - clock: The clock that times deadlines and retention. Tests pass a `TestClock`.
  /// - Returns: The running client.
  /// - Throws: ``StartupError/alreadyStarted`` when another client is running.
  public static func start(
    framework: any CallingFramework,
    media: any CallMedia,
    push: (any PushSource)? = nil,
    audio: (any AudioSession)? = nil,
    observers: [any CallObserver] = [],
    configuration: VoIPConfiguration = VoIPConfiguration(),
    clock: any Clock<Duration> = ContinuousClock()
  ) throws(StartupError) -> VoIPClient {
    let claimed = isRunning.withLock { isRunning in
      defer { isRunning = true }
      return !isRunning
    }
    guard claimed else { throw .alreadyStarted }
    let subscribers = Subscribers()
    let (snapshots, continuation) = AsyncStream.makeStream(of: Snapshot.self)
    let engine = CallEngine(
      framework: framework, media: media, audio: audio, pushSource: push,
      configuration: configuration, clock: clock, subscribers: subscribers,
      publish: { continuation.yield($0) })
    let client = VoIPClient(
      engine: engine, subscribers: subscribers, observers: observers, snapshots: snapshots)
    // The push source may deliver the push that cold-launched the app as soon as it attaches, so
    // observers subscribe first.
    for observer in observers { observer.attach(to: client) }
    Task { @VoIPActor in engine.attach() }
    return client
  }

  /// Returns a new stream of everything that happens to calls from now on.
  ///
  /// Each call returns a separate stream for one subscriber. Events that happen while nobody
  /// subscribes are not kept; the SDK performs actions without waiting for the app, and
  /// ``calls`` holds the current state.
  ///
  /// A stream created after ``start(framework:media:push:audio:observers:configuration:clock:)``
  /// returns can miss the first events of a cold launch, because the SDK may report the call of
  /// the VoIP push that launched the app before the app subscribes. To receive every event from
  /// the start, create the stream in the ``CallObserver/attach(to:)`` of an observer passed to
  /// `start`, which the client calls before it attaches the push source.
  public func events() -> AsyncStream<CallEvent> {
    subscribers.stream()
  }

  /// Requests an action on a call.
  ///
  /// Starting a call creates it; it then waits for the app to place it, which the app confirms
  /// with ``confirmPlaced(_:)``, or with ``confirmNotPlaced(_:)`` when it can't. Joining a call
  /// from its preview waits in the same way. Ending a call preview ends it without the calling
  /// framework.
  ///
  /// - Parameter action: The action to request.
  /// - Throws: ``ActionError/unknownCall`` when this device doesn't know the call,
  ///   ``ActionError/notAllowed(_:)`` when the call's status doesn't allow the action,
  ///   ``ActionError/unsupported`` when the configuration's capabilities don't include it, or
  ///   ``ActionError/refused`` when the calling framework refuses it. A start that the calling
  ///   framework refuses ends the call; a join returns to its preview.
  public func request(_ action: Action) async throws(ActionError) {
    try await engine.request(action)
  }

  /// Confirms that the app placed a call it was asked to start or join, after
  /// ``CallEvent/startRequested(_:)`` or ``CallEvent/joinRequested(_:)``.
  ///
  /// The SDK then prepares the call's media and completes the start or join. A call that isn't
  /// placed before ``Deadlines/placement`` ends with ``CallFailure/notPlaced``, or returns to its
  /// call preview.
  ///
  /// - Parameter id: The call the app placed.
  public func confirmPlaced(_ id: CallID) async {
    await engine.confirmPlaced(id)
  }

  /// Confirms that the app couldn't place a call it was asked to start or join, after
  /// ``CallEvent/startRequested(_:)`` or ``CallEvent/joinRequested(_:)``.
  ///
  /// Use it when placing the call fails, for example because the app's servers refused it,
  /// rather than waiting for ``Deadlines/placement`` to pass. The SDK fails the start or join in
  /// the calling framework at once: an outgoing call ends with ``CallFailure/notPlaced``, and a
  /// call being joined returns to its call preview. A call that the app already confirmed with
  /// ``confirmPlaced(_:)``, or that isn't being started or joined, is unaffected.
  ///
  /// ```swift
  /// for await event in client.events() {
  ///   guard case .startRequested(let call) = event else { continue }
  ///   do {
  ///     try await server.place(call)
  ///     await client.confirmPlaced(call.id)
  ///   } catch {
  ///     await client.confirmNotPlaced(call.id)
  ///   }
  /// }
  /// ```
  ///
  /// - Parameter id: The call the app couldn't place.
  public func confirmNotPlaced(_ id: CallID) async {
    await engine.confirmNotPlaced(id)
  }

  /// Presents an incoming call that the app learned about other than through a VoIP push, such as
  /// over its own connection.
  ///
  /// The call appears as its presentation policy asks. Only a call that rings is reported to the
  /// calling framework: a call preview returns ``PresentationOutcome/previewed(_:)`` with
  /// ``PreviewReason/policy``, and a call that doesn't appear returns
  /// ``PresentationOutcome/notShown``. A call that the system filtered returns
  /// ``PresentationOutcome/previewed(_:)`` with ``PreviewReason/filtered(_:)`` when the policy
  /// previews filtered calls, and ``PresentationOutcome/filtered(_:)`` when it ended. A call
  /// that would ring beyond ``VoIPConfiguration/maximumCalls`` ends with
  /// ``CallFailure/atCapacity``. Reporting a call this device already knows doesn't present it
  /// again; it returns the outcome of the first report.
  ///
  /// - Parameter call: The incoming call.
  /// - Returns: How the call appears on this device.
  public func report(_ call: IncomingCall) async -> PresentationOutcome {
    await engine.report(call)
  }

  /// Joins a call from its call preview, first creating the call when this device doesn't know
  /// it, such as a call whose preview the app's servers started before the app ran.
  ///
  /// A call that this device knows is joined as with ``request(_:)`` and ``Action/join(_:)``.
  /// Otherwise the call begins as a call preview with reason ``PreviewReason/policy``, without
  /// ``CallEvent/previewStarted(_:)``, because the user is joining it already, and the client asks
  /// the app to place the join with ``CallEvent/joinRequested(_:)``. Server events that arrived
  /// for the call before apply first: joining a call that already ended throws
  /// ``ActionError/notAllowed(_:)`` with its ended status. When the join fails, the call returns
  /// to its preview, with ``CallEvent/previewStarted(_:)``.
  ///
  /// - Parameter call: The call to join, with the details that the device knows of it. Its
  ///   presentation policy decides what happens if the call is answered elsewhere.
  /// - Throws: ``ActionError/notAllowed(_:)`` when the call can't be joined in its status, such
  ///   as a call that ended, or ``ActionError/refused`` when the calling framework refuses.
  public func join(_ call: IncomingCall) async throws(ActionError) {
    try await engine.join(call)
  }

  /// Applies a fact about a call that the app learned from its servers other than through a VoIP
  /// push.
  ///
  /// Use it for every event about a call that this device has answered or joined, or didn't
  /// present because Do Not Disturb or a Focus filtered it or it shows as a call preview, such as
  /// the call ending, which the app's servers send over the app's own connection or with a regular
  /// push rather than a VoIP push. An event whose ID the SDK has already seen is ignored, so the
  /// same event can arrive over several channels. An event for a call this device doesn't know
  /// yet is kept for ``VoIPConfiguration/retention`` and applied when the call arrives.
  ///
  /// - Parameters:
  ///   - event: The server event.
  ///   - id: The call it concerns.
  ///   - eventID: The event's identifier.
  public func receive(_ event: ServerEvent, for id: CallID, eventID: EventID) async {
    await engine.receive(event, for: id, eventID: eventID)
  }

  private func apply(_ snapshot: Snapshot) {
    guard snapshot.revision > revision else { return }
    revision = snapshot.revision
    if calls != snapshot.calls { calls = snapshot.calls }
    if isAudioActive != snapshot.isAudioActive { isAudioActive = snapshot.isAudioActive }
  }
}

/// Why the SDK couldn't start.
public enum StartupError: Error, Hashable, Sendable {
  /// Another client is running in this process, which has one calling framework provider.
  case alreadyStarted
}

/// The streams of everyone who subscribed to call events.
final class Subscribers: Sendable {
  private let continuations = Mutex<[Int: AsyncStream<CallEvent>.Continuation]>([:])
  private let nextKey = Atomic(0)

  func stream() -> AsyncStream<CallEvent> {
    let (stream, continuation) = AsyncStream.makeStream(of: CallEvent.self)
    let key = nextKey.add(1, ordering: .relaxed).oldValue
    continuations.withLock { $0[key] = continuation }
    continuation.onTermination = { [weak self] _ in
      _ = self?.continuations.withLock { $0.removeValue(forKey: key) }
    }
    return stream
  }

  func yield(_ event: CallEvent) {
    for continuation in continuations.withLock({ Array($0.values) }) {
      continuation.yield(event)
    }
  }
}
