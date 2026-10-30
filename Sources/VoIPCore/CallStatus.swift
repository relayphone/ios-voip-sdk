/// Where a call is in its life on this device.
public enum CallStatus: Hashable, Sendable {
  /// An incoming call is presented to the user and waits for an answer.
  case ringing
  /// The call is live elsewhere, and this device follows it in a call preview from which the user
  /// can join. The calling framework isn't involved, and the call never rings or opens audio here.
  case previewing
  /// An outgoing call is being placed, or the other side's device is ringing.
  case dialing
  /// The call was answered or joined, and its media is connecting.
  case connecting
  /// The call is connected.
  case connected
  /// The call's media was interrupted and is reconnecting.
  case reconnecting
  /// The call ended on this device.
  case ended(EndReason)
}

/// Why a call ended on this device.
public enum EndReason: Hashable, Sendable {
  /// The user or the app ended the call on this device, including declining it while it rang.
  case endedHere
  /// The other side, or the app's servers, ended the call.
  case endedRemotely
  /// Nobody answered the call while it rang.
  case unanswered
  /// The incoming call was taken somewhere other than this device: on another of the user's
  /// devices, or by a service acting for the user.
  case answeredElsewhere
  /// The incoming call was declined on another of the user's devices.
  case declinedElsewhere
  /// The system didn't present the incoming call because of the user's Do Not Disturb, Focus or
  /// block list.
  case filtered(FilterCause)
  /// The call failed.
  case failed(CallFailure)
}

/// Why the system filtered an incoming call.
public enum FilterCause: Hashable, Sendable {
  /// Do Not Disturb or a Focus silenced the call.
  case doNotDisturb
  /// The caller is on the user's block list.
  case blockList
  /// The calling framework filtered the call without saying why.
  case unspecified
}

/// Why a call failed.
public enum CallFailure: Hashable, Sendable {
  /// The calling framework refused to report or start the call.
  case refused
  /// This device already had as many calls as the app allows.
  case atCapacity
  /// The app didn't place an outgoing call, or join a call, before the placement deadline.
  case notPlaced
  /// The call's media couldn't be prepared before the media preparation deadline.
  case media
  /// The system didn't activate audio for the call before the audio activation deadline.
  case audioActivationTimedOut
  /// The call didn't connect before the connect deadline.
  case connectTimedOut
  /// The call didn't reconnect before the reconnect deadline.
  case reconnectTimedOut
  /// The calling framework stopped waiting for an action on the call to complete.
  case actionTimedOut
  /// The calling framework reset, which ends every call it presents.
  case frameworkReset
  /// The app's servers reported that the call failed.
  case server
}
