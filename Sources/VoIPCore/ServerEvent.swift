/// A fact about a call learned from the app's servers.
public enum ServerEvent: Hashable, Sendable {
  /// The call was answered, and its media is connecting.
  case connecting
  /// The call's media is connected, or has reconnected.
  case connected
  /// The call's media was interrupted and is reconnecting.
  case reconnecting
  /// The parties on the other side of the call changed.
  case partiesChanged([Party])
  /// The other side, or the app's servers, ended the call.
  case endedRemotely
  /// The incoming call was taken somewhere other than this device.
  case answeredElsewhere
  /// The incoming call was declined on another of the user's devices.
  case declinedElsewhere
  /// Nobody answered the call.
  case unanswered
  /// The call failed on the app's servers.
  case failed
}
