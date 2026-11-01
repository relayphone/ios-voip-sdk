/// Something that happened to a call, which the SDK tells the app about.
///
/// Each event that concerns one call carries a snapshot of that call taken after the change.
public enum CallEvent: Hashable, Sendable {
  /// The calling framework presented an incoming call, and it rings on this device.
  case presented(Call)
  /// This device started following the call in a call preview: the call was presented as one, or
  /// it was filtered or answered elsewhere and the presentation policy previews it, or joining it
  /// failed, after ``joinFailed(_:)``. The call's status holds the reason.
  case previewStarted(Call)
  /// The calling framework started an outgoing call. The app places it, then confirms it with
  /// ``VoIPClient/confirmPlaced(_:)``, or with ``VoIPClient/confirmNotPlaced(_:)`` when it can't.
  case startRequested(Call)
  /// The user asked to join the call from its preview. The app joins it, then confirms it with
  /// ``VoIPClient/confirmPlaced(_:)``, or with ``VoIPClient/confirmNotPlaced(_:)`` when it can't.
  case joinRequested(Call)
  /// Joining the call ended before the call took part on this device, and the call returned to
  /// its preview, which ``previewStarted(_:)`` follows. The calling framework refused or dropped
  /// the join, the app didn't place it, its media or audio failed, or the user ended it on the
  /// system's call screen. The call's status holds the preview's reason.
  ///
  /// The user asked to join the call, from any surface, so a ``CallObserver`` such as the call
  /// notifier can tell this preview from one that the user hasn't seen.
  case joinFailed(Call)
  /// The SDK performed an action on the call.
  case performed(Action, Call)
  /// The system activated the audio session. Microphone and speaker use for calls may start now.
  case audioActivated
  /// The system deactivated the audio session.
  case audioDeactivated
  /// The system interrupted the active audio session, which deactivated it, and microphone and
  /// speaker use for calls stopped.
  ///
  /// When the interruption ends, a call that takes part and isn't on hold ends with
  /// ``CallFailure/audioRecoveryTimedOut`` unless the system activates audio again within
  /// ``Deadlines/audioRecovery``.
  case audioInterrupted(AudioInterruptionReason)
  /// The system's media services reset, which ends every audio object in the app. Microphone and
  /// speaker use for calls stopped; recreate the media's audio objects before the next
  /// ``audioActivated``.
  ///
  /// The SDK configures the audio session again. A call that takes part and isn't on hold ends
  /// with ``CallFailure/audioRecoveryTimedOut`` unless the system activates audio again within
  /// ``Deadlines/audioRecovery``.
  case mediaServicesReset
  /// The call ended on this device. Its status holds the end reason.
  case ended(Call)
}
