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
  /// A source requires a report for every push that arrives while the app isn't active, whatever
  /// the system says: it creates each push's completion with
  /// ``PushCompletion/init(systemRequiresReport:appIsActive:finish:)``.
  ///
  /// - Parameter onPush: Receives each push and what completing it requires.
  func attach(onPush: @escaping @VoIPActor (VoIPPush, PushCompletion) -> Void)
}

/// A VoIP push, decoded by the app.
///
/// Apple requires every VoIP push to be reported as a call, so a server that wants a call to
/// appear only as a call preview sends a Live Activity push instead. When a VoIP push brings no
/// new call to present, such as a repeated push or a server event, and it must be reported (see
/// ``PushCompletion/mustReport``), the SDK satisfies the rule with a throwaway call: it reports a
/// call under a new UUID and ends it at once, which can show briefly on the call screen. It does
/// so even when the push concerns a call that the system presents, because the system doesn't
/// count a second report of a call it already has, and terminates the app.
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
/// ``EndReason/filtered(_:)``, and can tell your servers. Each VoIP push about such a call costs
/// a throwaway call while the app isn't active. On an iPhone 13 with iOS 27.1 and a Focus on, the
/// system said that `callEnded` VoIP pushes for calls that the Focus had filtered needn't be
/// reported while the app was in the background, so the SDK reported nothing for them, and the
/// system then terminated the app for not reporting a call, about 8 seconds after such a push, 6
/// times in four runs. After three terminations in 21 minutes, the system stopped delivering VoIP
/// pushes to the app, even once the user opened it, until the app was reinstalled. The SDK now
/// reports every push that arrives while the app isn't active.
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
  /// Whether the SDK must report the push as a call.
  ///
  /// When it is `false`, the SDK reports nothing that it wouldn't report for the same call outside
  /// a push. A push source decides it with ``init(systemRequiresReport:appIsActive:finish:)``, so
  /// it is `false` only while the app is active and the system doesn't require a report.
  public let mustReport: Bool

  /// Tells the system that the SDK is done with the push.
  ///
  /// The SDK calls it exactly once: after the calling framework answered the push's report, or at
  /// once when it reported nothing.
  public let finish: @VoIPActor @Sendable () -> Void

  /// Creates what completing a push requires.
  ///
  /// - Parameters:
  ///   - mustReport: Whether the SDK must report the push as a call.
  ///   - finish: Tells the system that the SDK is done with the push.
  public init(mustReport: Bool, finish: @escaping @VoIPActor @Sendable () -> Void) {
    self.mustReport = mustReport
    self.finish = finish
  }

  /// Creates what completing a push requires from whether the system requires a report and
  /// whether the app is active.
  ///
  /// From iOS 26.4, PushKit says whether the system requires each VoIP push to be reported, with
  /// `PKVoIPPushMetadata.mustReport`. The SDK reports a push when the system requires it, and
  /// whenever the app isn't active, whatever the system says. On an iPhone 13 with iOS 27.1, the
  /// system said that `callEnded` VoIP pushes needn't be reported while the app was in the
  /// background, then terminated the app for not reporting a call, and after three terminations it
  /// stopped delivering VoIP pushes to the app. Only while the app is active, in the foreground,
  /// does the SDK skip a report that the system doesn't require, which would show the system's
  /// call screen for nothing.
  ///
  /// - Parameters:
  ///   - systemRequiresReport: Whether the system requires the push to be reported as a call.
  ///     Before iOS 26.4, it always does.
  ///   - appIsActive: Whether the app is active, in the foreground. An app that a VoIP push
  ///     launches isn't.
  ///   - finish: Tells the system that the SDK is done with the push.
  public init(
    systemRequiresReport: Bool, appIsActive: Bool,
    finish: @escaping @VoIPActor @Sendable () -> Void
  ) {
    self.init(mustReport: systemRequiresReport || !appIsActive, finish: finish)
  }
}
