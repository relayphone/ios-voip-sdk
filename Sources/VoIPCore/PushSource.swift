/// Delivers the app's VoIP pushes to the SDK.
///
/// The PushKit adapter is the usual push source.
@VoIPActor
public protocol PushSource: Sendable {
  /// Starts delivering VoIP pushes.
  ///
  /// The source calls `onPush` for each push, synchronously from the system's push callback. The
  /// SDK reports the push's call to the calling framework before `onPush` returns, as Apple
  /// requires, and later calls the push's ``PushCompletion/finish`` exactly once.
  ///
  /// - Parameter onPush: Receives each push and what completing it requires.
  func attach(onPush: @escaping @VoIPActor (VoIPPush, PushCompletion) -> Void)
}

/// A VoIP push, decoded by the app.
///
/// Apple requires every VoIP push to be reported as a call, so a server that wants a call to
/// appear only as a call preview sends a Live Activity push instead. When a VoIP push brings no
/// new call to present, such as a repeated push or a server event, and the system requires a
/// report (see ``PushCompletion/mustReport``), the SDK satisfies the rule with a throwaway call: it
/// reports a call under a new UUID and ends it at once, which can show briefly on the call screen.
/// It does so even when the push concerns a call that the system presents, because the system
/// doesn't count a second report of a call it already has, and terminates the app.
///
/// So send a device VoIP pushes about a call only while the call may ring on it. Once the device
/// has answered or joined the call, or didn't present it, don't send it VoIP pushes about that
/// call. Tell the app what happens to the call, such as that it ended, over the app's own
/// connection to your servers or with a regular push, and pass it to
/// ``VoIPClient/receive(_:for:eventID:)``, as Apple recommends.
///
/// A device didn't present a call that Do Not Disturb or a Focus filtered, or that it shows as a
/// call preview. The app learns of it from ``CallEvent/previewStarted(_:)`` with
/// ``PreviewReason/filtered(_:)`` or ``PreviewReason/policy``, or when the call ends as
/// ``EndReason/filtered(_:)``, and can tell your servers. On an iPhone 13 with a Focus on, the
/// system terminated an app in the background for not reporting a call, about 8 seconds after the
/// third of three `callEnded` VoIP pushes for calls that the Focus had filtered, sent a few
/// seconds apart, although the SDK had reported a throwaway call for each push within a second.
public enum VoIPPush: Hashable, Sendable {
  /// A push announcing an incoming call.
  case incoming(IncomingCall, eventID: EventID)
  /// A push carrying a server event about a call, such as answered elsewhere.
  case serverEvent(ServerEvent, for: CallID, eventID: EventID)
  /// A push that the app couldn't decode.
  case unrecognized
}

/// What the SDK must do before it is done with a VoIP push.
public struct PushCompletion: Sendable {
  /// Whether the system requires the push to be reported as a call.
  ///
  /// When it is `false`, the SDK reports nothing that it wouldn't report for the same call outside
  /// a push.
  public let mustReport: Bool

  /// Tells the system that the SDK is done with the push.
  ///
  /// The SDK calls it exactly once: after the calling framework answered the push's report, or at
  /// once when it reported nothing.
  public let finish: @VoIPActor @Sendable () -> Void

  /// Creates what completing a push requires.
  ///
  /// - Parameters:
  ///   - mustReport: Whether the system requires the push to be reported as a call.
  ///   - finish: Tells the system that the SDK is done with the push.
  public init(mustReport: Bool, finish: @escaping @VoIPActor @Sendable () -> Void) {
    self.mustReport = mustReport
    self.finish = finish
  }
}
