/// The app's audio session as calls use it: Apple's `AVAudioSession`, which the SDK configures
/// for each call and watches for interruptions and media services resets.
///
/// Only the system activates and deactivates the audio session for calls, and the calling
/// framework tells the SDK when it does; an audio session never activates itself. The SDK
/// configures it for a call before it prepares the call's media, so the configuration is in place
/// when the SDK completes the answer, start or join after which the system activates audio.
///
/// `AudioSessionAdapter`, in the `VoIPAudio` library, is the audio session that apps pass to
/// ``VoIPClient/start(framework:media:push:audio:observers:configuration:clock:)``. Without one,
/// the app configures `AVAudioSession` for calls itself.
@VoIPActor
public protocol AudioSession: Sendable {
  /// Starts watching the audio session.
  ///
  /// The SDK calls this once, before any other method. The audio session calls `onEvent` for
  /// every interruption and media services reset, in the order the system reports them.
  ///
  /// - Parameter onEvent: Receives the audio session's events.
  func attach(onEvent: @escaping @VoIPActor (AudioSessionEvent) -> Void)

  /// Configures the audio session for a call that is about to take part on this device, without
  /// activating it.
  ///
  /// The SDK calls this before it prepares a call's media for an answer, start or join, and after
  /// the media services reset, for the newest call that takes part. When it throws, the call ends
  /// with ``CallFailure/audioSession``, or a join returns to its call preview.
  ///
  /// - Parameter call: The call that is about to take part, which may have video.
  /// - Throws: ``AudioSessionError/configurationFailed`` when the system refuses the
  ///   configuration.
  func configure(for call: Call) throws(AudioSessionError)
}

/// Something the audio session tells the SDK.
public enum AudioSessionEvent: Hashable, Sendable {
  /// The system interrupted the audio session, which deactivated it.
  case interruptionBegan(AudioInterruptionReason)
  /// The interruption ended, so the system can activate the audio session again.
  case interruptionEnded
  /// The system's media services reset. Every audio object in the app is gone, and the audio
  /// session is inactive and has lost its configuration.
  case mediaServicesReset
}

/// Why the system interrupted the audio session.
public enum AudioInterruptionReason: Hashable, Sendable {
  /// Another audio session became active, such as Siri's or another app's. `AVAudioSession`
  /// calls this the default reason.
  case otherAudio
  /// The built-in microphone was muted, for example by closing an iPad's Smart Folio.
  case builtInMicMuted
  /// The audio route was disconnected.
  case routeDisconnected
}

/// Why the audio session couldn't be configured for a call.
public enum AudioSessionError: Error, Hashable, Sendable {
  /// The system refused the category, mode or options.
  case configurationFailed
}
