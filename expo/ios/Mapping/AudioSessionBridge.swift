#if SWIFT_PACKAGE
  import VoIPCore
#endif

/// Lets media remember the app's session before the SDK configures it for a call.
@VoIPActor
final class AudioSessionBridge: AudioSession {
  private let adapter: any AudioSession
  private let willConfigure: @VoIPActor @Sendable () -> Void

  nonisolated init(
    adapter: any AudioSession, willConfigure: @escaping @VoIPActor @Sendable () -> Void
  ) {
    self.adapter = adapter
    self.willConfigure = willConfigure
  }

  func attach(onEvent: @escaping @VoIPActor (AudioSessionEvent) -> Void) {
    adapter.attach(onEvent: onEvent)
  }

  func configure(for call: Call) throws(AudioSessionError) {
    willConfigure()
    try adapter.configure(for: call)
  }
}
