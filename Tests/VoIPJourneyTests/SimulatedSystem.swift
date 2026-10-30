#if os(iOS) && targetEnvironment(simulator)
  import CKSimProtocol
  import Foundation
  import Testing

  /// The simulator runtime's control mailbox, through which a journey acts as the system: it
  /// delivers VoIP pushes, filters calls, and performs the user's actions on the call screen.
  struct SimulatedSystem {
    /// A runtime that doesn't answer a control within this time has stopped.
    private static let responseLimit = Duration.seconds(10)

    private let mailbox: URL
    private let identity: RuntimeIdentity

    /// Connects to the runtime that activated in this process.
    init() throws {
      let documents = try #require(
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
      let root = documents.appending(path: ".callkit-simulator")
      let session = try JSONDecoder().decode(
        RuntimeSession.self, from: Data(contentsOf: root.appending(path: "session.json")))
      identity = try RuntimeIdentity(
        bundleID: session.bundleID, runID: session.runID, pid: session.pid)
      mailbox = root.appending(path: session.runID)
    }

    /// Delivers a VoIP push to the app's PushKit registry, or keeps it until the app registers.
    ///
    /// - Returns: The push's identifier in the runtime's journal.
    func push(_ fields: [String: PushPayload.Value], mustReport: Bool = true) async throws -> UUID {
      guard
        case .push(let id) = try await send(
          .push(PushPayload(fields: fields), mustReport: mustReport))
      else { throw JourneyError("The runtime didn't schedule the push") }
      return id
    }

    /// Performs a user's action on the system's call screen.
    func perform(_ control: ControlRequest.CallControl) async throws {
      _ = try await send(.call(control))
    }

    /// Makes the system filter incoming calls, as Do Not Disturb does, or stop filtering them.
    func filterIncomingCalls(_ reason: ControlRequest.FilterReason) async throws {
      _ = try await send(.incomingFilter(reason))
    }

    /// The runtime's calls.
    func calls() async throws -> [CallSnapshot.State] {
      guard case .status(let snapshot) = try await send(.status) else {
        throw JourneyError("The runtime didn't return its status")
      }
      return snapshot.calls.map(\.state)
    }

    /// The runtime's journal.
    func journal() async throws -> [JournalEntry] {
      guard case .events(let text) = try await send(.events) else {
        throw JourneyError("The runtime didn't return its journal")
      }
      return try text.split(separator: "\n").map {
        try JSONDecoder().decode(JournalEntry.self, from: Data($0.utf8))
      }
    }

    /// Writes a control to the mailbox and waits for the runtime's response.
    private func send(_ operation: ControlRequest.Operation) async throws -> ControlResult {
      let request = try ControlRequest(id: UUID(), target: identity, operation: operation)
      let name = request.id.uuidString
      let staged = mailbox.appending(path: "\(name).staged")
      try JSONEncoder().encode(request).write(to: staged)
      // The runtime watches for the rename into its requests directory.
      try FileManager.default.moveItem(
        at: staged, to: mailbox.appending(path: "requests/\(name).json"))
      let response = mailbox.appending(path: "responses/\(name).json")
      let deadline = ContinuousClock.now + Self.responseLimit
      while !FileManager.default.fileExists(atPath: response.path()) {
        guard ContinuousClock.now < deadline else {
          throw JourneyError("The runtime didn't answer \(operation.name)")
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      return try JSONDecoder().decode(ControlResponse.self, from: Data(contentsOf: response)).get()
    }
  }

  /// One event in the runtime's journal, with the fields the journeys check.
  struct JournalEntry: Decodable {
    let event: String
    let pushID: String?
    /// Why the runtime recorded a diagnostic.
    let reason: String?

    private enum CodingKeys: String, CodingKey {
      case event, pushID, reason
    }

    init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      event = try values.decode(String.self, forKey: .event)
      pushID = try? values.decodeIfPresent(String.self, forKey: .pushID)
      // Other events use the field for numeric codes.
      reason = try? values.decodeIfPresent(String.self, forKey: .reason)
    }
  }

  struct JourneyError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
      self.description = description
    }
  }
#endif
