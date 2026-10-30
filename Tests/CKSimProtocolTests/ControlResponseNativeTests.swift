import CKSimProtocol
import Darwin
import Foundation
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["CKSIM_NATIVE_CHANNEL"] != nil))
struct ControlResponseNativeTests {
  struct JournalEntry: Decodable {
    let sequence: UInt64
    let event: String
    let requestID: String?
    let commandID: String?
    let uuid: UUID?
    let ringing: Bool?
    let ended: Bool?
    let actionID: UUID?
  }

  @Test func liveMailboxPreservesRejectionCacheAndWriteRetry() async throws {
    let root = URL(
      fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CKSIM_NATIVE_CHANNEL"]))
    let session = try JSONDecoder().decode(
      RuntimeSession.self, from: Data(contentsOf: root.appendingPathComponent("session.json")))
    let target = try RuntimeIdentity(
      bundleID: session.bundleID, runID: session.runID, pid: session.pid)
    let mailbox = root.appendingPathComponent(session.runID)
    let requests = mailbox.appendingPathComponent("requests")
    let responses = mailbox.appendingPathComponent("responses")
    let journal = mailbox.appendingPathComponent("events.jsonl")
    let clock = ContinuousClock()
    func entries() throws -> [JournalEntry] {
      let bytes = try Data(contentsOf: journal)
      var lines = bytes.split(separator: 10)
      if bytes.last != 10 && !lines.isEmpty { lines.removeLast() }
      return try lines.map { try JSONDecoder().decode(JournalEntry.self, from: Data($0)) }
    }
    func publish(_ bytes: Data, id: UUID) throws {
      try bytes.write(
        to: requests.appendingPathComponent("\(id.uuidString).json"), options: .atomic)
    }
    func response(_ id: UUID) async throws -> Data {
      let file = responses.appendingPathComponent("\(id.uuidString).json")
      let deadline = clock.now.advanced(by: .seconds(8))
      while clock.now < deadline {
        if let bytes = try? Data(contentsOf: file) { return bytes }
        try await clock.sleep(for: .milliseconds(20))
      }
      throw CocoaError(.fileReadNoSuchFile)
    }
    func check(_ bytes: Data, id: UUID, success: Bool) throws {
      let reply = try JSONDecoder().decode(ControlResponse.self, from: bytes)
      #expect(reply.id == id && reply.target == target)
      switch reply.outcome {
      case .success: #expect(success)
      case .failure(let failure): #expect(!success && !failure.message.isEmpty)
      }
    }
    func request(_ id: UUID, _ operation: ControlRequest.Operation) throws -> Data {
      try JSONEncoder().encode(ControlRequest(id: id, target: target, operation: operation))
    }
    func send(_ operation: ControlRequest.Operation) async throws -> ControlResponse {
      let id = UUID()
      try publish(request(id, operation), id: id)
      let bytes = try await response(id)
      try check(bytes, id: id, success: true)
      return try JSONDecoder().decode(ControlResponse.self, from: bytes)
    }
    func waitFor(_ predicate: () throws -> Bool) async throws {
      let deadline = clock.now.advanced(by: .seconds(8))
      while !(try predicate()) && clock.now < deadline {
        try await clock.sleep(for: .milliseconds(20))
      }
      #expect(try predicate())
    }
    let cachedID = UUID()
    let original = try request(cachedID, .status)
    try publish(original, id: cachedID)
    let originalReply = try await response(cachedID)
    try check(originalReply, id: cachedID, success: true)
    let filterID = UUID()
    try publish(request(filterID, .incomingFilter(.none)), id: filterID)
    try check(await response(filterID), id: filterID, success: true)
    try FileManager.default.removeItem(at: responses.appendingPathComponent("\(cachedID).json"))
    try publish(original, id: cachedID)
    #expect(try await response(cachedID) == originalReply)

    for code in [4, 0] {
      let reply = try await send(.faults([.incomingErrorCode(code)]))
      #expect(try reply.get() == .faults(incomingErrorCode: code))
    }
    for reason in [ControlRequest.FilterReason.doNotDisturb, .none] {
      let reply = try await send(.incomingFilter(reason))
      guard case .incomingFilter(let state) = try reply.get() else {
        Issue.record("Expected filter result")
        return
      }
      #expect(state.reason == reason)
    }
    let events = try await send(.events)
    guard case .events(let text) = try events.get() else {
      Issue.record("Expected journal text")
      return
    }
    #expect(text.contains("runtime.installed"))
    let before = try entries()
    for body in [
      #""operation":"status","held":true"#, #""operation":"unknown""#,
      #""operation":"faults","faults":{"incomingErrorCode":4,"incomingErrorCode":0}"#,
      #""operation":"faults","faults":{"incomingErrorCode":4.000000000000000001}"#,
      #""operation":"push","mustReport":false,"payload":{"n":18446744073709551617}"#,
    ] {
      let id = UUID()
      let prefix =
        "\"id\":\"\(id)\",\"runID\":\"\(target.runID)\",\"pid\":\(target.pid),\"bundleID\":\"\(target.bundleID)\""
      try publish(Data("{\(prefix),\(body)}".utf8), id: id)
      try check(await response(id), id: id, success: false)
      #expect(
        try entries().contains { $0.event == "control.rejected" && $0.requestID == id.uuidString })
    }
    let after = try entries()
    #expect(
      after.filter { $0.event == "faults.configured" }.count
        == before.filter { $0.event == "faults.configured" }.count)
    #expect(
      after.filter { $0.event == "push.received" }.count
        == before.filter { $0.event == "push.received" }.count)

    for filenameMismatch in [false, true] {
      let id = UUID()
      let bodyID = filenameMismatch ? UUID() : id
      let bytes =
        filenameMismatch
        ? try request(bodyID, .status)
        : Data(
          String(decoding: try request(id, .status), as: UTF8.self)
            .replacingOccurrences(of: "\"pid\":\(target.pid)", with: "\"pid\":\(target.pid + 1)")
            .utf8)
      try publish(bytes, id: id)
      let file = requests.appendingPathComponent("\(id).json")
      let deadline = clock.now.advanced(by: .seconds(8))
      while FileManager.default.fileExists(atPath: file.path) && clock.now < deadline {
        try await clock.sleep(for: .milliseconds(20))
      }
      #expect(!FileManager.default.fileExists(atPath: file.path))
      #expect(
        !FileManager.default.fileExists(atPath: responses.appendingPathComponent("\(id).json").path)
      )
      #expect(
        !FileManager.default.fileExists(
          atPath: responses.appendingPathComponent("\(bodyID).json").path)
      )
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: responses.path)
    let mode = try #require(attributes[.posixPermissions] as? NSNumber).uint16Value
    #expect(chmod(responses.path, 0o500) == 0)
    defer { _ = chmod(responses.path, mode_t(mode)) }
    let retryID = UUID()
    let retry = try request(retryID, .status)
    try publish(retry, id: retryID)
    let deadline = clock.now.advanced(by: .seconds(8))
    while !(try entries().contains {
      $0.event == "control.responseWriteFailed" && $0.commandID == retryID.uuidString
    }) && clock.now < deadline {
      try await clock.sleep(for: .milliseconds(20))
    }
    #expect(
      try entries().contains {
        $0.event == "control.responseWriteFailed" && $0.commandID == retryID.uuidString
      })
    #expect(
      FileManager.default.fileExists(
        atPath: requests.appendingPathComponent("\(retryID).json").path))
    #expect(chmod(responses.path, mode_t(mode)) == 0)
    try publish(retry, id: retryID)
    let retryBytes = try await response(retryID)
    try check(retryBytes, id: retryID, success: true)
    let retried = try JSONDecoder().decode(ControlResponse.self, from: retryBytes)
    guard case .status(let snapshot) = try retried.get() else {
      Issue.record("Expected cached status")
      return
    }
    let failedWrite = try #require(
      entries().first {
        $0.event == "control.responseWriteFailed" && $0.commandID == retryID.uuidString
      })
    #expect(snapshot.sequence + 1 == failedWrite.sequence)

    let knownCalls = Set(try entries().compactMap(\.uuid))
    let push = try await send(
      .push(PushPayload(fields: ["operation": .string("incoming")]), mustReport: false))
    #expect(try push.get() == .push(pushID: push.id))
    try await waitFor {
      try entries().contains {
        $0.ringing == true && $0.uuid.map { !knownCalls.contains($0) } == true
      }
    }
    let call = try #require(
      entries().last { $0.ringing == true && $0.uuid.map { !knownCalls.contains($0) } == true }?
        .uuid)
    let status = try await send(.status)
    guard case .status(let current) = try status.get() else {
      Issue.record("Expected live status")
      return
    }
    let incoming = try #require(current.calls.first { $0.state.uuid == call })
    #expect(incoming.state.ringing && incoming.relationship == .callkit(group: call))
    #expect(!current.providerConfigurations.isEmpty)
    for operation in [ControlRequest.CallControl.answer(call), .end(call)] {
      let reply = try await send(.call(operation))
      guard case .actions(let ids, _) = try reply.get() else {
        Issue.record("Expected delivered action identities")
        return
      }
      try await waitFor {
        try ids.allSatisfy { id in
          try entries().contains { $0.event == "action.settled" && $0.actionID == id }
        }
      }
    }
    let reset = try await send(.reset)
    guard case .reset(let provider) = try reset.get() else {
      Issue.record("Expected provider reset")
      return
    }
    #expect(!provider.isEmpty && UUID(uuidString: provider) == nil)
    print("Typed mailbox verification passed")
  }
}
