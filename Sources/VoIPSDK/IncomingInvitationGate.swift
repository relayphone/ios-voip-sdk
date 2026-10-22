import Foundation

/// One gate for PushKit and foreground reports. Registration happens before any suspension.
struct IncomingInvitationGate {
  struct Registration { let id: UUID; let isNew: Bool }
  private struct Event { let id: UUID; let at: Date }
  private var events: [String: Event] = [:]
  private struct Server { let id: UUID; let at: Date; var active: Bool }
  private var servers: [String: Server] = [:]

  mutating func register(eventId: String, serverCallId: String, now: Date) -> Registration {
    events = events.filter { now.timeIntervalSince($0.value.at) <= 120 }
    servers = servers.filter { $0.value.active || now.timeIntervalSince($0.value.at) <= 120 }
    if let event = events[eventId] { return Registration(id: event.id, isNew: false) }
    if let server = servers[serverCallId] {
      events[eventId] = Event(id: server.id, at: now)
      return Registration(id: server.id, isNew: false)
    }
    let id = UUID()
    events[eventId] = Event(id: id, at: now)
    servers[serverCallId] = Server(id: id, at: now, active: true)
    return Registration(id: id, isNew: true)
  }

  /// Reporting failed before the manager ever owned this UUID; permit a real retry.
  mutating func discardUnreported(_ id: UUID) {
    events = events.filter { $0.value.id != id }
    servers = servers.filter { $0.value.id != id }
  }

  /// Re-reporting an ended UUID may be accepted by LCK; live membership wins over expiry.
  mutating func markActive(_ id: UUID, serverCallId: String, now: Date) {
    if var server = servers[serverCallId] {
      guard server.id == id else { return }
      server.active = true; servers[serverCallId] = server
    } else { servers[serverCallId] = Server(id: id, at: now, active: true) }
  }

  func conversation(serverCallId: String) -> UUID? { servers[serverCallId]?.id }
  mutating func removeConversation(_ id: UUID, now: Date = Date()) {
    for (key, var server) in servers where server.id == id {
      if now.timeIntervalSince(server.at) <= 120 { server.active = false; servers[key] = server }
      else { servers.removeValue(forKey: key) }
    }
  }
}
