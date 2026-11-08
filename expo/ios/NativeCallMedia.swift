import Synchronization
import os

/// The app's own native media for calls, which joins each call's media before JavaScript loads.
///
/// By default, the module only coordinates the audio session, and the app's JavaScript connects
/// each call's media, such as its LiveKit room. A call answered on a locked phone after a cold
/// launch then has no audio until JavaScript has loaded and connected. Register a `CallMedia`
/// instead, and the SDK prepares each call's media natively before it completes the answer,
/// start or join, then activates and deactivates it with the audio session. The module passes
/// the SDK's `AudioSessionAdapter`, which configures play-and-record in voice chat mode before
/// the media prepares. The media must not set the session's category itself. JavaScript can still
/// observe routes with `useAudioRoutes()` and select one with `selectAudioRoute(id)`.
///
/// Register from an app delegate subscriber of the app's own, in
/// `application(_:willFinishLaunchingWithOptions:)`, which runs before the module starts calls in
/// `application(_:didFinishLaunchingWithOptions:)`:
///
/// ```swift
/// public final class CallMediaSubscriber: ExpoAppDelegateSubscriber {
///   public func application(
///     _ application: UIApplication,
///     willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
///   ) -> Bool {
///     let calls = RoomCalls()
///     NativeCallMedia.register(calls.media, observers: [calls])
///     return true
///   }
/// }
/// ```
///
/// The observers follow calls from the moment the client starts: the module passes them to
/// `VoIPClient.start(framework:media:push:audio:observers:configuration:clock:)` after its own.
/// Use one to leave a call's media when the call ends, and to report the call's transport with
/// `VoIPClient.receive(_:for:eventID:)`, such as `.connected` once the media connected.
///
/// The media reads the short-lived credentials of an incoming call's VoIP push, its `media`
/// object, with ``mediaCredentials(for:)``.
///
/// JavaScript learns of it afterwards: each conversation whose media the registered media prepared
/// has `media: "native"`, and its status follows the reports. Don't connect its media from
/// JavaScript too.
@MainActor
public enum NativeCallMedia {
  private static let log = Logger(subsystem: "VoIPConversations", category: "media")

  /// The registered media and observers, which the module uses when it starts calls.
  private(set) static var registration: (media: any CallMedia, observers: [any CallObserver])?

  /// Uses the app's media for every call instead of the module's, which only coordinates the
  /// audio session for the app's JavaScript media.
  ///
  /// Register once, before the module starts calls. The module's `mediaAdapter` doesn't apply
  /// then. The SDK configures the session through `AudioSessionAdapter` before
  /// `CallMedia.prepare(_:)`; the media must not set its category. Use the session only between
  /// `activate()` and `deactivate()`. The system activates it for calls, and the module's
  /// JavaScript routes API remains available.
  ///
  /// - Parameters:
  ///   - media: The app's media.
  ///   - observers: Objects that follow calls from the moment the client starts, such as one that
  ///     leaves each call's media when it ends and reports its transport.
  public static func register(_ media: any CallMedia, observers: [any CallObserver] = []) {
    guard !CallService.shared.isStarted else {
      log.fault(
        """
        NativeCallMedia.register(_:observers:) was called after the module started calls; \
        call it from application(_:willFinishLaunchingWithOptions:)
        """)
      assertionFailure("NativeCallMedia.register(_:observers:) was called too late")
      return
    }
    registration = (media, observers)
  }

  /// The `media` object of the VoIP push, or of the `reportIncomingConversation` payload, that
  /// brought an incoming call: short-lived credentials for joining its media, such as
  /// `{ "provider": "livekit", "url": …, "room": …, "identity": …, "token": …, "expiresAt": … }`.
  ///
  /// The module never shows them to JavaScript, and forgets them when the call ends. Read them in
  /// `CallMedia.prepare(_:)`; don't log them.
  ///
  /// - Parameter id: The incoming call.
  /// - Returns: The credentials, or `nil` when the payload had none or the call ended.
  public nonisolated static func mediaCredentials(for id: CallID) -> [String: JSONValue]? {
    PushIntake.shared.credentials(for: id)
  }
}

/// The app's registered media, which records the calls whose media it prepared, so that their
/// conversations show it.
@VoIPActor
final class RegisteredMedia: CallMedia {
  /// The calls whose media the app's media prepared. The main actor reads it to show their
  /// conversations.
  nonisolated static let prepared = Mutex<Set<CallID>>([])

  private let media: any CallMedia
  private let changed: @MainActor @Sendable () -> Void

  /// Wraps the app's media.
  ///
  /// - Parameters:
  ///   - media: The app's media.
  ///   - changed: Called on the main actor when the media prepared a call.
  nonisolated init(_ media: any CallMedia, changed: @escaping @MainActor @Sendable () -> Void) {
    self.media = media
    self.changed = changed
  }

  func prepare(_ call: Call) async throws {
    try await media.prepare(call)
    try Task.checkCancellation()
    Self.prepared.withLock { _ = $0.insert(call.id) }
    Task { @MainActor [changed] in changed() }
  }

  func activate() {
    media.activate()
  }

  func deactivate() {
    media.deactivate()
  }

  func release(_ call: Call) {
    media.release(call)
    Self.prepared.withLock { _ = $0.remove(call.id) }
    Task { @MainActor [changed] in changed() }
  }
}
