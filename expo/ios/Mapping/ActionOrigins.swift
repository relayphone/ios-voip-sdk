#if SWIFT_PACKAGE
  import VoIPCore
#endif

/// Correlates app requests with placement and performed events, which arrive separately.
struct ActionOrigins {
  private var requested: [Action] = []

  mutating func append(_ action: Action) { requested.append(action) }

  func placement(for id: CallID) -> ConversationEncoding.Origin {
    requested.contains { Self.places($0, id) } ? .app : .system
  }

  mutating func take(_ action: Action) -> ConversationEncoding.Origin {
    guard let index = requested.firstIndex(of: action) else { return .system }
    requested.remove(at: index)
    return .app
  }

  mutating func withdraw(_ action: Action) {
    if let index = requested.firstIndex(of: action) { requested.remove(at: index) }
  }

  mutating func cancelPlacement(for id: CallID) {
    requested.removeAll { Self.places($0, id) }
  }

  mutating func ended(_ id: CallID) {
    requested.removeAll { $0.callID == id }
  }

  private static func places(_ action: Action, _ id: CallID) -> Bool {
    switch action {
    case .start(let call): call.id == id
    case .join(let joined): joined == id
    default: false
    }
  }
}
