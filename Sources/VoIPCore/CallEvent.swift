/// Something that happened to a call, which the SDK tells the app about.
///
/// Each event that concerns one call carries a snapshot of that call taken after the change.
public enum CallEvent: Hashable, Sendable {
  /// The calling framework presented an incoming call, and it rings on this device.
  case presented(Call)
  /// This device started following the call in a call preview: the call was presented as one, or
  /// it was filtered or answered elsewhere and the presentation policy previews it, or joining it
  /// failed.
  case previewStarted(Call)
  /// The calling framework started an outgoing call. The app places it, then confirms it.
  case startRequested(Call)
  /// The user asked to join the call from its preview. The app joins it, then confirms it.
  case joinRequested(Call)
  /// The SDK performed an action on the call.
  case performed(Action, Call)
  /// The system activated the audio session. Microphone and speaker use for calls may start now.
  case audioActivated
  /// The system deactivated the audio session.
  case audioDeactivated
  /// The call ended on this device. Its status holds the end reason.
  case ended(Call)
}
