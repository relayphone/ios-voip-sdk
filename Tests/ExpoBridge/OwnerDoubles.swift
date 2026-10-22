import Foundation

// Only the platform-owning facades are replaced. Models, handler closures,
// cancellation signals, token encoding and the relay itself are production code.
@MainActor
final class ConversationClient {
  private(set) var handler: ConversationHandler?
  private var states: [UUID: @MainActor (ConversationStateUpdate) -> Void] = [:]
  private var events: [UUID: @MainActor (ConversationEvent) -> Void] = [:]
  var state = ConversationStateUpdate(revision: 0, conversations: [])
  var stateObserverCount: Int { states.count }
  var eventObserverCount: Int { events.count }

  func setConversationHandler(_ handler: ConversationHandler?) { self.handler = handler }
  func observeState(_ callback: @escaping @MainActor (ConversationStateUpdate) -> Void) -> UUID {
    let id = UUID(); states[id] = callback; callback(state); return id
  }
  func removeStateObserver(_ id: UUID) { states.removeValue(forKey: id) }
  func observeEvents(_ callback: @escaping @MainActor (ConversationEvent) -> Void) -> UUID {
    let id = UUID(); events[id] = callback; return id
  }
  func removeEventObserver(_ id: UUID) { events.removeValue(forKey: id) }
  func publish(_ update: ConversationStateUpdate) {
    state = update
    for callback in Array(states.values) { callback(update) }
  }
  func publish(_ event: ConversationEvent) {
    for callback in Array(events.values) { callback(event) }
  }
}

@MainActor
final class PushService {
  private let tokens = PushTokenStore()
  private var observers: Set<UUID> = []
  var tokenState: PushTokenState { tokens.state }
  var observerCount: Int { observers.count }
  func observeToken(_ callback: @escaping @MainActor (PushTokenState) -> Void) -> UUID {
    let id = tokens.observe(callback); observers.insert(id); return id
  }
  func removeTokenObserver(_ id: UUID) { observers.remove(id); tokens.removeObserver(id) }
  func publish(_ data: Data?) { tokens.update(data) }
}

@MainActor
final class VoIPApplication {
  static var fixture: VoIPApplication?
  let client = ConversationClient()
  let pushService = PushService()
  static func startFromBundle() throws -> VoIPApplication {
    guard let fixture else { throw BridgeError.unavailable }
    return fixture
  }
}
