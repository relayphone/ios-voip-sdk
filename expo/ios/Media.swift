#if VOIP_CONVERSATIONS_WEBRTC
  import AVFAudio
  internal import VoIPConversationsWebRTC

  /// Call media for apps whose real-time media is WebRTC: react-native-webrtc, LiveKit React
  /// Native, or another build that ships WebRTC's `RTCAudioSession`.
  ///
  /// WebRTC runs in manual audio mode, so it never activates the audio session itself: the
  /// calling framework does. Before a call takes part, the audio session gets WebRTC's voice or
  /// video chat configuration; when the system activates it, WebRTC starts its audio unit, and
  /// when the system deactivates it, WebRTC stops and the session's earlier configuration
  /// returns. The app's JavaScript connects the call's room or peer connection as before.
  @VoIPActor
  final class RTCAudioSessionMedia: CallMedia {
    /// The audio session's configuration before the first call prepared it.
    private lazy var configuration = CallAudioConfiguration<
      (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)
    >(restore: Self.restore)

    /// Puts WebRTC in manual audio mode with its configuration for audio calls, before the app's
    /// JavaScript can create a peer connection.
    nonisolated init() {
      guard let session = try? Self.session(),
        let configurationClass = try? WebRTCClass.configuration.resolve(),
        let configuration = try? Self.configuration(hasVideo: false)
      else { return }
      session.useManualAudio = true
      session.isAudioEnabled = false
      VoIPRTCAudioSessionConfigurationSetWebRTC(configurationClass, configuration)
    }

    func rememberConfiguration() {
      let audio = AVAudioSession.sharedInstance()
      configuration.remember((audio.category, audio.mode, audio.categoryOptions))
    }

    func prepare(_ call: Call) async throws {
      rememberConfiguration()
      let session = try Self.session()
      session.lockForConfiguration()
      defer { session.unlockForConfiguration() }
      try session.setConfiguration(Self.configuration(hasVideo: call.hasVideo))
    }

    func activate() {
      guard let session = try? Self.session() else { return }
      session.audioSessionDidActivate(AVAudioSession.sharedInstance())
      session.isAudioEnabled = true
    }

    func deactivate() {
      guard let session = try? Self.session() else { return }
      session.isAudioEnabled = false
      session.audioSessionDidDeactivate(AVAudioSession.sharedInstance())
      configuration.deactivate()
    }

    private static func restore(
      _ earlier: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)
    ) {
      guard let session = try? Self.session() else { return }
      let (category, mode, options) = earlier
      guard let configuration = try? Self.configuration(hasVideo: false) else { return }
      configuration.category = category.rawValue
      configuration.mode = mode.rawValue
      configuration.categoryOptions = options
      session.lockForConfiguration()
      defer { session.unlockForConfiguration() }
      try? session.setConfiguration(configuration)
    }

    private nonisolated static func session() throws(WebRTCClass.Missing) -> any VoIPRTCAudioSession
    {
      VoIPRTCAudioSessionSharedInstance(try WebRTCClass.audioSession.resolve())
    }

    /// WebRTC's configuration for a call: voice chat, or video chat on the speaker.
    private nonisolated static func configuration(hasVideo: Bool) throws(WebRTCClass.Missing)
      -> any VoIPRTCAudioSessionConfiguration
    {
      let configuration = VoIPRTCAudioSessionConfigurationCreate(
        try WebRTCClass.configuration.resolve())
      configuration.category = AVAudioSession.Category.playAndRecord.rawValue
      configuration.categoryOptions =
        hasVideo
        ? [.allowBluetoothHFP, .allowBluetoothA2DP, .allowAirPlay, .defaultToSpeaker]
        : [.allowBluetoothHFP, .allowBluetoothA2DP, .allowAirPlay]
      configuration.mode = (hasVideo ? AVAudioSession.Mode.videoChat : .voiceChat).rawValue
      return configuration
    }
  }
#endif

/// Call media for apps that manage the audio session themselves, with `mediaAdapter: "none"`.
///
/// The SDK still completes answers and starts at once, and JavaScript learns of audio activation
/// from the `audioActivated` event.
@VoIPActor
final class AppManagedMedia: CallMedia {
  nonisolated init() {}

  func prepare(_ call: Call) async throws {}

  func activate() {}

  func deactivate() {}
}
