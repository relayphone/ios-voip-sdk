#if SWIFT_PACKAGE
  public import VoIPCore
#endif

/// An audio session that records the calls the SDK configures it for, so that the SDK can be
/// tested without `AVAudioSession`.
///
/// Use ``send(_:)`` to interrupt the session or reset the media services, as the system does.
@VoIPActor
public final class FakeAudioSession: AudioSession {
  /// Every call the SDK configured the session for, in order, as it was when configured.
  public private(set) var configuredCalls: [Call] = []

  /// Whether configuring the session fails with `AudioSessionError.configurationFailed`.
  /// Defaults to `false`.
  public var failsConfiguration = false

  private var onEvent: (@VoIPActor (AudioSessionEvent) -> Void)?

  /// Creates a fake audio session that accepts every configuration.
  public nonisolated init() {}

  /// Sends the SDK an event, as the system does.
  ///
  /// - Parameter event: The event to send.
  public func send(_ event: AudioSessionEvent) {
    guard let onEvent else { preconditionFailure("The SDK hasn't attached the audio session") }
    onEvent(event)
  }

  // MARK: AudioSession

  /// Starts sending events to the SDK.
  public func attach(onEvent: @escaping @VoIPActor (AudioSessionEvent) -> Void) {
    self.onEvent = onEvent
  }

  /// Records the call, then fails if ``failsConfiguration`` says so.
  public func configure(for call: Call) throws(AudioSessionError) {
    configuredCalls.append(call)
    if failsConfiguration { throw .configurationFailed }
  }
}
