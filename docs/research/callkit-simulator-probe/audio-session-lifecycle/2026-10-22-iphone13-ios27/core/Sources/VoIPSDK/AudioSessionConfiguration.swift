#if canImport(AVFAudio) && (os(iOS) || os(watchOS))
import AVFAudio
#if canImport(VoIPPlatform)
import VoIPPlatform
#endif

private enum AudioSessionExecutionError: Error { case wrongExecutor }

enum AudioSessionConfiguration {
  /// Synchronous so a WebRTC adapter can keep its non-reentrant configuration
  /// lock around the complete configuration block without holding it across await.
  static func applyOnAudioQueue(permit: AudioPreparationPermit?) throws {
    guard VSAudioSessionIsOnQueue() else { throw AudioSessionExecutionError.wrongExecutor }
    try permit?.check()
    let session = AVAudioSession.sharedInstance()
    #if os(iOS)
    try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
    #else
    try session.setCategory(.playAndRecord, mode: .voiceChat)
    #endif
  }
}

extension AudioSessionQueue {
  public func configureForConversation() throws {
    try Self.checkCancellation()
    try AudioSessionConfiguration.applyOnAudioQueue(permit: AudioPreparationScope.permit)
  }
}
#endif
