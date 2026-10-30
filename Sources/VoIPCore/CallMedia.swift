/// The app's real-time audio and video transport for calls.
///
/// The SDK prepares a call's media before it completes the answer, start or join that makes the
/// call take part on this device, then starts and stops audio as the system activates and
/// deactivates the audio session.
@VoIPActor
public protocol CallMedia: Sendable {
  /// Prepares a call's media, such as connecting to its room, before the call takes part on this
  /// device.
  ///
  /// Don't use the microphone or speaker yet; wait for ``activate()``. The SDK cancels the task
  /// when the call stops waiting for its media, for example because it ended. When preparation
  /// throws, or takes longer than ``Deadlines/mediaPreparation``, the call ends with
  /// ``CallFailure/media``, or a join returns to its call preview.
  ///
  /// - Parameter call: The call whose media to prepare.
  func prepare(_ call: Call) async throws

  /// Starts using the microphone and speaker, now that the system activated the audio session.
  func activate()

  /// Stops using the audio session, which the system deactivated.
  func deactivate()
}
