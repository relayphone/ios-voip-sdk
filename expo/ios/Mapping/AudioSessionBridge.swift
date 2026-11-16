#if SWIFT_PACKAGE
  import VoIPCore
#endif

/// Lets media remember the app's session before the SDK configures it for a call.
@VoIPActor
final class AudioSessionBridge: AudioSession {
  private let adapter: any AudioSession
  private let configuresCalls: Bool
  private let didUpdateVideo: @VoIPActor @Sendable (Call) -> Void
  private let willConfigure: @VoIPActor @Sendable () -> Void

  nonisolated init(
    adapter: any AudioSession, configuresCalls: Bool = true,
    didUpdateVideo: @escaping @VoIPActor @Sendable (Call) -> Void = { _ in },
    willConfigure: @escaping @VoIPActor @Sendable () -> Void
  ) {
    self.adapter = adapter
    self.configuresCalls = configuresCalls
    self.didUpdateVideo = didUpdateVideo
    self.willConfigure = willConfigure
  }

  func attach(onEvent: @escaping @VoIPActor (AudioSessionEvent) -> Void) {
    adapter.attach(onEvent: onEvent)
  }

  func updateVideo(for call: Call) throws(AudioSessionError) {
    try adapter.updateVideo(for: call)
    didUpdateVideo(call)
  }

  func configure(for call: Call) throws(AudioSessionError) {
    guard configuresCalls else { return }
    willConfigure()
    try adapter.configure(for: call)
  }
}
