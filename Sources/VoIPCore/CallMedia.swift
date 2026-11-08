/// The app's real-time audio and video transport for calls.
///
/// The SDK prepares a call's media before it completes the answer, start or join that makes the
/// call take part on this device, then starts and stops audio as the system activates and
/// deactivates the audio session, or interrupts it.
///
/// `activate()`, `deactivate()` and `release(_:)` are synchronous on `VoIPActor`, so main-actor media must forward
/// them in order through one stream rather than separate tasks.
/// See <doc:MainActorMedia> for preparation, ordered audio commands and attempt tokens.
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

  /// Stops using the audio session, which the system deactivated or interrupted, or which the
  /// media services reset.
  ///
  /// The SDK calls it only after ``activate()``, once per activation. After
  /// ``CallEvent/mediaServicesReset``, recreate the media's audio objects before the next
  /// ``activate()``.
  func deactivate()

  /// The call no longer takes part on this device: it ended, or returned to its call preview.
  /// Release what ``prepare(_:)`` set up for it, such as leaving its room.
  ///
  /// Called exactly once after each successful preparation, including when a join later fails.
  /// Never called for a preparation that threw or was cancelled. Held calls remain prepared.
  /// This callback runs synchronously on ``VoIPActor``, in order with ``activate()`` and
  /// ``deactivate()``. If audio is still active, release comes before its final deactivation;
  /// if the system already deactivated audio, release follows that callback. Release does not
  /// itself deactivate the session. Main-actor media forwards all three through one ordered stream.
  ///
  /// - Parameter call: The call's snapshot after it ended or returned to its preview.
  func release(_ call: Call)
}

extension CallMedia {
  /// Keeps media that needs no per-call cleanup source compatible.
  public func release(_ call: Call) {}
}
