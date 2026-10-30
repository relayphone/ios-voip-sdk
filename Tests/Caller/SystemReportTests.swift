import Foundation

struct Handle: Hashable, Sendable {
  enum Kind: Sendable { case phoneNumber, emailAddress, generic }
  let type: Kind
  let value: String
  let displayName: String?
}
enum Conversation {
  struct Capabilities: OptionSet, Sendable {
    let rawValue: Int
    static let pausing = Self(rawValue: 1)
    static let playingTones = Self(rawValue: 8), video = Self(rawValue: 16)
  }
  struct Update: Sendable { let members: Set<Handle>; let capabilities: Capabilities }
}
final class ConversationManager: @unchecked Sendable {
  private let lock = NSLock()
  private var reports: [(UUID, Conversation.Update)] = []
  func reportNewIncomingConversation(uuid: UUID, update: Conversation.Update) async throws {
    lock.withLock { reports.append((uuid, update)) }
  }
  var recorded: [(UUID, Conversation.Update)] { lock.withLock { reports } }
}
enum ConversationSystemErrors {
  static func isAlreadyReported(_ error: any Error) -> Bool { false }
}

@main struct SystemReportTests {
  static func main() async throws {
    let manager = ConversationManager()
    let transport = IncomingReportTransport(manager: manager)
    let intake = IncomingIntake()
    let samples: [(String, String, String, Handle.Kind, String)] = [
      ("phone", "+1 (202) 555-0123", "Phone caller", .phoneNumber, "+12025550123"),
      ("email", "Alice@example.com", "Email caller", .emailAddress, "Alice@example.com"),
      ("generic", "opaque-id", "Generic caller", .generic, "opaque-id")
    ]
    for (type, input, name, nativeType, expected) in samples {
      let wire: [AnyHashable: Any] = ["incomingCall": ["eventId": "event-" + type,
        "serverCallId": "server-" + type, "hasVideo": true,
        "caller": ["handleType": type, "value": input, "displayName": name, "hostContactID": "host-" + type]]]
      guard case .incoming(let payload) = PushWire.parse(wire) else { preconditionFailure("Typed push rejected") }
      let reservation = try intake.reserve(payload, source: .pushKit)
      guard case .reported = await transport.report(reservation) else { preconditionFailure("Report failed") }
      let report = manager.recorded.last!
      precondition(report.0 == reservation.id)
      precondition(report.1.members == [Handle(type: nativeType, value: expected, displayName: name)])
      precondition(report.1.capabilities.contains(.video))
      precondition(payload.caller.hostContactID == "host-" + type)
    }
    precondition(manager.recorded.count == 3)
    print("passed: exact typed phone/email/generic identity from push through production incoming report transport")
  }
}
