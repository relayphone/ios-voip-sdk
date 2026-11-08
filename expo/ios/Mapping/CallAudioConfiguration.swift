#if SWIFT_PACKAGE
  import VoIPCore
#endif

/// The audio configuration to restore when WebRTC deactivates its session.
@VoIPActor
final class CallAudioConfiguration<Value: Sendable> {
  private var earlier: Value?
  private let restore: @VoIPActor @Sendable (Value) -> Void

  init(restore: @escaping @VoIPActor @Sendable (Value) -> Void) { self.restore = restore }

  func remember(_ value: @autoclosure () -> Value) {
    if earlier == nil { earlier = value() }
  }

  func deactivate() {
    guard let earlier else { return }
    self.earlier = nil
    restore(earlier)
  }
}
