/// Canonical IDs and remote aliases occupy separate namespaces.
enum ServerEventTarget: Hashable {
  case canonical(CallID)
  case alias(RemoteCallID)
}

/// Arrival-ordered windows for deduplication and for events awaiting identity resolution.
struct ServerEventHistory {
  struct BufferedEvent {
    let id: EventID
    let target: ServerEventTarget
    let event: ServerEvent
    let receipt: CallMachine.ServerReceipt
  }

  private var seen: [(id: EventID, receivedAt: Duration)] = []
  private var buffered: [BufferedEvent] = []
  private var sequence: UInt64 = 0

  mutating func remember(_ id: EventID, at now: Duration, limit: Int) -> CallMachine.ServerReceipt?
  {
    guard !seen.contains(where: { $0.id == id }), !buffered.contains(where: { $0.id == id })
    else { return nil }
    sequence += 1
    seen.append((id, now))
    seen.removeFirst(max(0, seen.count - max(1, limit)))
    return .init(receivedAt: now, sequence: sequence)
  }

  mutating func buffer(
    _ event: ServerEvent, target: ServerEventTarget, id: EventID,
    receipt: CallMachine.ServerReceipt, limit: Int
  ) {
    buffered.append(.init(id: id, target: target, event: event, receipt: receipt))
    buffered.removeFirst(max(0, buffered.count - max(1, limit)))
  }

  mutating func takeBuffered(for target: ServerEventTarget) -> [BufferedEvent] {
    let matching = buffered.filter { $0.target == target }
    buffered.removeAll { $0.target == target }
    return matching
  }

  func hasBufferedEnd(for target: ServerEventTarget) -> Bool {
    buffered.contains {
      $0.target == target && $0.event.endReason != nil && $0.event != .answeredElsewhere
    }
  }

  mutating func prune(at now: Duration, after retention: Duration) {
    seen.removeAll { now - $0.receivedAt >= retention }
    buffered.removeAll { now - $0.receipt.receivedAt >= retention }
  }
}
