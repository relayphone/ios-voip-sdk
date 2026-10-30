/// The app's choice of how an incoming call appears on this device: ring, preview, or not at all.
///
/// By default an incoming call rings, and a call that the system filtered, or that was answered
/// elsewhere, is shown as a call preview. Set a policy for every call in
/// ``VoIPConfiguration/presentationPolicy``, or for one call in
/// ``IncomingCall/presentationPolicy``. An explicit answer or end by the user always wins over
/// the policy.
public struct PresentationPolicy: Hashable, Sendable {
  /// How an incoming call appears on this device.
  public enum Presentation: Hashable, Sendable {
    /// The calling framework presents the call on the system call screen, and it rings.
    case ring
    /// The call appears as a call preview, such as a Live Activity, from which the user can join,
    /// with reason ``PreviewReason/policy``. It never rings and opens no audio.
    ///
    /// The calling framework isn't involved, so a server must not send a VoIP push for a call
    /// that only appears as a preview: Apple requires every VoIP push to be reported as a call.
    /// Send a Live Activity push instead. When a VoIP push brings such a call anyway, the SDK
    /// reports a call to satisfy the rule and ends it at once.
    case preview
    /// The call doesn't appear on this device.
    case none
  }

  /// How a new incoming call appears. Defaults to ``Presentation/ring``.
  public var incoming: Presentation

  /// Whether a call that the system filtered because of Do Not Disturb, Focus or the block list
  /// becomes a call preview, with reason ``PreviewReason/filtered(_:)``. Otherwise it ends as
  /// ``EndReason/filtered(_:)``. Defaults to `true`.
  ///
  /// The SDK never presents a filtered call again, because that would override the user's choice.
  public var previewsFilteredCalls: Bool

  /// Whether a call answered elsewhere becomes a call preview on this device, with reason
  /// ``PreviewReason/answeredElsewhere``. Otherwise it ends as ``EndReason/answeredElsewhere``.
  /// Defaults to `true`.
  public var previewsCallsAnsweredElsewhere: Bool

  /// Creates a presentation policy.
  ///
  /// - Parameters:
  ///   - incoming: How a new incoming call appears.
  ///   - previewsFilteredCalls: Whether a filtered call becomes a call preview.
  ///   - previewsCallsAnsweredElsewhere: Whether a call answered elsewhere becomes a call preview.
  public init(
    incoming: Presentation = .ring,
    previewsFilteredCalls: Bool = true,
    previewsCallsAnsweredElsewhere: Bool = true
  ) {
    self.incoming = incoming
    self.previewsFilteredCalls = previewsFilteredCalls
    self.previewsCallsAnsweredElsewhere = previewsCallsAnsweredElsewhere
  }
}

/// What the system did with an incoming call the SDK reported to it.
public enum PresentationOutcome: Hashable, Sendable {
  /// The system presented the call, and it rings.
  case presented
  /// The system didn't present the call because of the user's Do Not Disturb, Focus or block
  /// list.
  case filtered(FilterCause)
  /// The calling framework refused the call.
  case refused(CallFailure)
}
