#if SWIFT_PACKAGE
  import VoIPCore
#endif

/// Keeps call audio configured until every prepared call is released and audio is inactive.
@VoIPActor
final class CallAudioConfiguration<Value: Sendable> {
  private var earlier: Value?
  private var calls: [CallID: Value] = [:]
  private var order: [CallID] = []
  private var isActive = false
  private let apply: @VoIPActor @Sendable (Value) -> Void

  init(apply: @escaping @VoIPActor @Sendable (Value) -> Void) { self.apply = apply }

  func remember(_ value: @autoclosure () -> Value) {
    if earlier == nil { earlier = value() }
  }

  func prepared(_ id: CallID, configuration: Value) {
    calls[id] = configuration
    order.removeAll { $0 == id }
    order.append(id)
  }

  func activate() {
    if let id = order.last, let configuration = calls[id] { apply(configuration) }
    isActive = true
  }

  func deactivate() {
    isActive = false
    restoreIfIdle()
  }

  func release(_ id: CallID) {
    calls[id] = nil
    order.removeAll { $0 == id }
    restoreIfIdle()
  }

  func restoreIfIdle() {
    guard calls.isEmpty, !isActive, let earlier else { return }
    self.earlier = nil
    apply(earlier)
  }
}
