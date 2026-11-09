#if SWIFT_PACKAGE
  import VoIPCore
#endif

/// Retains distinct incoming outcomes until JavaScript can receive them.
struct IncomingOutcomeBuffer {
  private var waiting: [JSONValue] = []

  /// Returns an outcome for immediate delivery, or holds the most recent 16 in arrival order.
  mutating func receive(_ outcome: JSONValue, listenerAttached: Bool) -> [JSONValue] {
    guard listenerAttached else {
      waiting.append(outcome)
      if waiting.count > 16 { waiting.removeFirst() }
      return []
    }
    return [outcome]
  }

  /// Takes held outcomes once, when a listener becomes available.
  mutating func flush() -> [JSONValue] {
    let outcomes = waiting
    waiting.removeAll()
    return outcomes
  }
}
