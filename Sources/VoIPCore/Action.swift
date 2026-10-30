/// A request to change a call, made by the user through the system's calling surfaces or by the
/// app.
///
/// The SDK performs every action itself and then informs the app, except starting an outgoing
/// call or joining one, which waits for the app to place it.
public enum Action: Hashable, Sendable {
  /// Start an outgoing call.
  case start(OutgoingCall)
  /// Answer a ringing call. LiveCommunicationKit calls this joining.
  case answer(CallID)
  /// Start taking part on this device in a call that is live elsewhere, usually from its call
  /// preview. The SDK starts it through the calling framework, as it does an outgoing call.
  case join(CallID)
  /// End a call, or decline it while it rings.
  case end(CallID)
  /// Put a call on hold, or take it off hold. LiveCommunicationKit calls this pausing.
  case hold(CallID, onHold: Bool)
  /// Mute or unmute this device's microphone for a call.
  case mute(CallID, muted: Bool)
  /// Play DTMF tones on a call.
  case playTones(CallID, digits: String)
  /// Merge a call with another call. The app mixes the media; merging is off unless the
  /// configuration's capabilities include ``VoIPConfiguration/Capabilities/merging``.
  case merge(CallID, with: CallID)
  /// Split a call out of the calls it was merged with.
  case unmerge(CallID)

  /// The call the action applies to.
  public var callID: CallID {
    switch self {
    case .start(let call): call.id
    case .answer(let id), .join(let id), .end(let id), .unmerge(let id): id
    case .hold(let id, _), .mute(let id, _), .playTones(let id, _), .merge(let id, _): id
    }
  }
}

/// Why the SDK refused an action.
public enum ActionError: Error, Hashable, Sendable {
  /// The action doesn't apply to a call with this status, such as answering a call that isn't
  /// ringing.
  case notAllowed(CallStatus)
  /// The action needs a capability that the configuration turns off, such as merging.
  case unsupported
}
