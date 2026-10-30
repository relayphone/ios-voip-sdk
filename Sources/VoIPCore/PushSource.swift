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
/// appear only as a call preview sends a Live Activity push instead. When a VoIP push brings
/// nothing to present, the SDK satisfies the rule without presenting anything: it reports a call
/// and ends it at once.
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
