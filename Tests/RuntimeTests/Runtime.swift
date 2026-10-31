#if os(iOS) && targetEnvironment(simulator)
  import CKSimProtocol
  import CKSimRuntime
  import Foundation
  import Testing

  /// The suites that share this process's simulator runtime. They run one at a time, because the
  /// runtime is the process's call service: one provider presents calls, and audio is shared.
  @Suite(.serialized, .timeLimit(.minutes(3)))
  @MainActor
  enum RuntimeSuites {}

  /// The simulator runtime activated in this test process. Tests act as the system through its
  /// control mailbox, as the `cksim` tool does, and observe it through its journal.
  @MainActor
  final class Runtime {
    /// How long a test waits for something the runtime does in real time.
    static let limit = Duration.seconds(12)

    private static var activated: Runtime?

    let session: RuntimeSession
    let identity: RuntimeIdentity
    /// `Documents/.callkit-simulator`.
    let root: URL
    /// The run's mailbox and journal.
    var mailbox: URL { root.appending(path: session.runID) }
    var journal: URL { mailbox.appending(path: "events.jsonl") }

    /// The runtime, activated on first use.
    static func shared() throws -> Runtime {
      if let activated { return activated }
      try #require(RuntimeBootstrap.activate(), "The simulator runtime didn't activate")
      let runtime = try Runtime()
      activated = runtime
      return runtime
    }

    private init() throws {
      let documents = try #require(
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
      root = documents.appending(path: ".callkit-simulator")
      session = try JSONDecoder().decode(
        RuntimeSession.self, from: Data(contentsOf: root.appending(path: "session.json")))
      identity = try RuntimeIdentity(
        bundleID: session.bundleID, runID: session.runID, pid: session.pid)
    }

    /// Publishes a control and waits for the runtime's response.
    func send(_ operation: ControlRequest.Operation) async throws -> ControlResponse {
      let request = try ControlRequest(id: UUID(), target: identity, operation: operation)
      return try await send(JSONEncoder().encode(request), id: request.id)
    }

    /// Publishes a control and returns its result, failing the test if the runtime rejects it.
    @discardableResult
    func control(_ operation: ControlRequest.Operation) async throws -> ControlResult {
      try await send(operation).get()
    }

    /// Publishes raw request bytes under `id`, as a host tool does, and waits for the response.
    func send(_ bytes: Data, id: UUID) async throws -> ControlResponse {
      try JSONDecoder().decode(ControlResponse.self, from: await publish(bytes, id: id))
    }

    /// Publishes raw request bytes under `id` and returns the raw response.
    func publish(_ bytes: Data, id: UUID) async throws -> Data {
      try stage(bytes, id: id)
      let response = mailbox.appending(path: "responses/\(id.uuidString).json")
      return try await until("the response to \(id)") { try? Data(contentsOf: response) }
    }

    /// Publishes raw request bytes under `id` without waiting for a response.
    func stage(_ bytes: Data, id: UUID) throws {
      let staged = mailbox.appending(path: "\(id.uuidString).staged")
      try bytes.write(to: staged)
      // The runtime watches for the rename into its requests directory.
      try FileManager.default.moveItem(
        at: staged, to: mailbox.appending(path: "requests/\(id.uuidString).json"))
    }

    /// The runtime's current status.
    func status() async throws -> RuntimeSnapshot {
      guard case .status(let snapshot) = try await control(.status) else {
        throw RuntimeTestError("The runtime didn't return its status")
      }
      return snapshot
    }

    /// Delivers a call control as the system's call screen does, and returns the actions the
    /// runtime delivered.
    @discardableResult
    func perform(_ control: ControlRequest.CallControl) async throws -> [UUID] {
      guard case .actions(let ids, _) = try await self.control(.call(control)) else {
        throw RuntimeTestError("The runtime didn't deliver \(control.name)")
      }
      return ids
    }

    /// Delivers a VoIP push and returns its identifier.
    @discardableResult
    func push(_ fields: [String: PushPayload.Value], mustReport: Bool = true) async throws
      -> UUID
    {
      guard
        case .push(let id) = try await control(
          .push(PushPayload(fields: fields), mustReport: mustReport))
      else { throw RuntimeTestError("The runtime didn't schedule the push") }
      return id
    }

    /// Every complete entry in the run's journal.
    func entries() throws -> [Entry] {
      let bytes = try Data(contentsOf: journal)
      var lines = bytes.split(separator: 10)
      if bytes.last != 10, !lines.isEmpty { lines.removeLast() }
      return try lines.map { try JSONDecoder().decode(Entry.self, from: Data($0)) }
    }

    /// The journal's entries after `cursor`, a count of entries taken earlier.
    func entries(after cursor: Int) throws -> [Entry] {
      Array(try entries().dropFirst(cursor))
    }

    /// The number of entries in the journal, to read later entries after.
    func cursor() throws -> Int { try entries().count }

    /// Waits until `find` returns a value, polling as the runtime moves on in real time.
    @discardableResult
    func until<T>(
      _ description: String, limit: Duration = Runtime.limit,
      sourceLocation: SourceLocation = #_sourceLocation, _ find: () async throws -> T?
    ) async throws -> T {
      let deadline = ContinuousClock.now + limit
      while true {
        if let value = try await find() { return value }
        guard ContinuousClock.now < deadline else {
          throw RuntimeTestError("Timed out waiting for \(description)", sourceLocation)
        }
        try await Task.sleep(for: .milliseconds(20))
      }
    }

    /// Waits for the first journal entry after `cursor` that matches.
    @discardableResult
    func entry(
      _ description: String, after cursor: Int = 0, limit: Duration = Runtime.limit,
      sourceLocation: SourceLocation = #_sourceLocation, where matches: (Entry) -> Bool
    ) async throws -> Entry {
      try await until(description, limit: limit, sourceLocation: sourceLocation) {
        try entries(after: cursor).first(where: matches)
      }
    }

    /// Clears every fault and the incoming filter.
    func clearSettings() async throws {
      try await control(
        .faults([
          .staleAudio(false), .reportCallbackDelayMS(0), .invalidateDuringHandoff(false),
          .incomingErrorCode(0),
        ]))
      try await control(.incomingFilter(.none))
    }

    /// Ends the calls with the system's End control, then waits until the runtime has none of
    /// them, no pending action and no active audio.
    func end(_ calls: some Sequence<UUID>) async throws {
      let calls = Set(calls)
      for call in try await status().calls.map(\.state.uuid) where calls.contains(call) {
        _ = try? await send(.call(.end(call)))
      }
      try await until("the calls to end and the audio to stop") {
        let status = try await status()
        let live = status.calls.contains { calls.contains($0.state.uuid) }
        return live || status.pending > 0 || status.audioActive ? nil : true
      }
    }
  }

  /// One journal entry, with the fields the tests check. Fields the runtime writes with more than
  /// one type, such as `error`, decode only in the type a test reads.
  struct Entry: Decodable {
    struct Conversation: Decodable {
      let callUUID: String
      let state: String
    }

    let schemaVersion: Int
    let sequence: Int
    let runID: String
    let pid: Int
    let bundleID: String
    let event: String
    /// Milliseconds since the runtime started.
    let time: Int
    let wallTimeMS: Int

    var uuid: String?
    var callUUID: String?
    var actionID: String?
    var actionIDs: [String]?
    var transactionID: String?
    var pushID: String?
    var reportID: String?
    var requestID: String?
    var commandID: String?
    var kind: String?
    var origin: String?
    var apiKind: String?
    var state: String?
    var domain: String?
    var filterReason: String?
    var verification: String?
    var handle: String?
    var policy: String?
    var label: String?
    var name: String?
    var reason: String?
    var code: Int?
    var error: Int?
    var errorDomain: String?
    var errorCode: Int?
    var incomingErrorCode: Int?
    var replyCount: Int?
    var connected: Bool?
    var held: Bool?
    var ended: Bool?
    var muted: Bool?
    var ringing: Bool?
    var fulfilled: Bool?
    var failed: Bool?
    var main: Bool?
    var success: Bool?
    var reportEntered: Bool?
    var latencyMS: Double?
    var deadlineMS: Double?
    var deadlineSeconds: Double?
    var issuedAtMS: Int?
    var advertisedDeadlineMS: Double?
    var conversations: [Conversation]?

    private enum Key: String, CodingKey {
      case schemaVersion, sequence, runID, pid, bundleID, event, wallTimeMS
      case time = "t_ms"
      case uuid, callUUID, actionID, actionIDs, transactionID, pushID, reportID, requestID
      case commandID, kind, origin, apiKind, state, domain, filterReason, verification, handle
      case policy, label, name, reason, code, error, errorDomain, errorCode, incomingErrorCode
      case replyCount, connected, held, ended, muted, ringing, fulfilled, failed, main, success
      case reportEntered, latencyMS, deadlineMS, deadlineSeconds, issuedAtMS
      case advertisedDeadlineMS, conversations
    }

    init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: Key.self)
      schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
      sequence = try values.decode(Int.self, forKey: .sequence)
      runID = try values.decode(String.self, forKey: .runID)
      pid = try values.decode(Int.self, forKey: .pid)
      bundleID = try values.decode(String.self, forKey: .bundleID)
      event = try values.decode(String.self, forKey: .event)
      time = try values.decode(Int.self, forKey: .time)
      wallTimeMS = try values.decode(Int.self, forKey: .wallTimeMS)
      func optional<T: Decodable>(_ key: Key) -> T? {
        try? values.decodeIfPresent(T.self, forKey: key)
      }
      uuid = optional(.uuid)
      callUUID = optional(.callUUID)
      actionID = optional(.actionID)
      actionIDs = optional(.actionIDs)
      transactionID = optional(.transactionID)
      pushID = optional(.pushID)
      reportID = optional(.reportID)
      requestID = optional(.requestID)
      commandID = optional(.commandID)
      kind = optional(.kind)
      origin = optional(.origin)
      apiKind = optional(.apiKind)
      state = optional(.state)
      domain = optional(.domain)
      filterReason = optional(.filterReason)
      verification = optional(.verification)
      handle = optional(.handle)
      policy = optional(.policy)
      label = optional(.label)
      name = optional(.name)
      reason = optional(.reason)
      code = optional(.code)
      error = optional(.error)
      errorDomain = optional(.errorDomain)
      errorCode = optional(.errorCode)
      incomingErrorCode = optional(.incomingErrorCode)
      replyCount = optional(.replyCount)
      connected = optional(.connected)
      held = optional(.held)
      ended = optional(.ended)
      muted = optional(.muted)
      ringing = optional(.ringing)
      fulfilled = optional(.fulfilled)
      failed = optional(.failed)
      main = optional(.main)
      success = optional(.success)
      reportEntered = optional(.reportEntered)
      latencyMS = optional(.latencyMS)
      deadlineMS = optional(.deadlineMS)
      deadlineSeconds = optional(.deadlineSeconds)
      issuedAtMS = optional(.issuedAtMS)
      advertisedDeadlineMS = optional(.advertisedDeadlineMS)
      conversations = optional(.conversations)
    }
  }

  struct RuntimeTestError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String, _ sourceLocation: SourceLocation? = nil) {
      self.description = sourceLocation.map { "\(description) (\($0))" } ?? description
    }
  }
#endif
