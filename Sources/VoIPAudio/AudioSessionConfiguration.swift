#if SWIFT_PACKAGE
  import VoIPCore
#endif

/// How the SDK configures the audio session for calls.
///
/// The SDK always sets the play-and-record category in voice chat mode, which lets calls use
/// Bluetooth hands-free (HFP) devices, such as AirPods and cars, for both the microphone and the
/// speaker. These settings choose the other routes that calls can use.
public struct AudioSessionConfiguration: Hashable, Sendable {
  /// Whether calls can play through Bluetooth devices that only play audio (A2DP), such as
  /// speakers, while recording through another microphone. Defaults to `true`.
  ///
  /// A device that supports both HFP and A2DP uses HFP for calls.
  public var allowsBluetoothA2DP: Bool

  /// Whether calls can play through AirPlay devices. Defaults to `false`.
  public var allowsAirPlay: Bool

  /// Whether a call with video plays through the built-in speaker, rather than the receiver, when
  /// no headset or other route is connected. Defaults to `true`.
  ///
  /// The receiver isn't an available route while this applies.
  public var videoCallsDefaultToSpeaker: Bool

  /// Creates a configuration.
  ///
  /// - Parameters:
  ///   - allowsBluetoothA2DP: Whether calls can play through Bluetooth devices that only play
  ///     audio.
  ///   - allowsAirPlay: Whether calls can play through AirPlay devices.
  ///   - videoCallsDefaultToSpeaker: Whether a call with video plays through the built-in speaker.
  public init(
    allowsBluetoothA2DP: Bool = true,
    allowsAirPlay: Bool = false,
    videoCallsDefaultToSpeaker: Bool = true
  ) {
    self.allowsBluetoothA2DP = allowsBluetoothA2DP
    self.allowsAirPlay = allowsAirPlay
    self.videoCallsDefaultToSpeaker = videoCallsDefaultToSpeaker
  }

  /// The category options for a call, set with the play-and-record category in voice chat mode.
  func options(for call: Call) -> CategoryOptions {
    var options: CategoryOptions = [.allowBluetoothHFP]
    if allowsBluetoothA2DP { options.insert(.allowBluetoothA2DP) }
    if allowsAirPlay { options.insert(.allowAirPlay) }
    if call.hasVideo, videoCallsDefaultToSpeaker { options.insert(.defaultToSpeaker) }
    return options
  }
}
