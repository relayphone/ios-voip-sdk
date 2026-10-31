#if os(iOS) && targetEnvironment(simulator)
  import CKSimProtocol
  import Darwin
  import Foundation
  import Testing

  extension RuntimeSuites {
    /// The runtime's control mailbox: typed requests and responses, rejections, replayed
    /// responses and a failed response write.
    @Suite @MainActor struct Mailbox {
      private let runtime: Runtime
      private let app: CallKitApp

      init() throws {
        runtime = try Runtime.shared()
        app = CallKitApp()
      }

      private var requests: URL { runtime.mailbox.appending(path: "requests") }
      private var responses: URL { runtime.mailbox.appending(path: "responses") }

      private func request(_ id: UUID, _ operation: ControlRequest.Operation) throws -> Data {
        try JSONEncoder().encode(
          ControlRequest(id: id, target: runtime.identity, operation: operation))
      }

      @Test func aRepeatedRequestGetsItsOriginalResponse() async throws {
        defer { app.stop() }
        let id = UUID()
        let original = try request(id, .status)
        let reply = try await runtime.publish(original, id: id)
        #expect(try JSONDecoder().decode(ControlResponse.self, from: reply).id == id)
        try await runtime.control(.incomingFilter(.none))
        try FileManager.default.removeItem(at: responses.appending(path: "\(id.uuidString).json"))
        #expect(try await runtime.publish(original, id: id) == reply)
      }

      @Test func faultsAndFiltersReturnWhatTheyApplied() async throws {
        defer { app.stop() }
        for code in [4, 0] {
          #expect(
            try await runtime.control(.faults([.incomingErrorCode(code)]))
              == .faults(incomingErrorCode: code))
        }
        for reason in [ControlRequest.FilterReason.doNotDisturb, .none] {
          guard case .incomingFilter(let state) = try await runtime.control(.incomingFilter(reason))
          else { throw RuntimeTestError("Expected the filter") }
          #expect(state.reason == reason)
        }
        guard case .events(let text) = try await runtime.control(.events) else {
          throw RuntimeTestError("Expected the journal")
        }
        #expect(text.contains("runtime.installed"))
      }

      @Test(arguments: [
        #""operation":"status","held":true"#, #""operation":"unknown""#,
        #""operation":"faults","faults":{"incomingErrorCode":4,"incomingErrorCode":0}"#,
        #""operation":"faults","faults":{"incomingErrorCode":4.000000000000000001}"#,
        #""operation":"push","mustReport":false,"payload":{"n":18446744073709551617}"#,
      ])
      func anInvalidRequestIsRejectedWithoutEffect(body: String) async throws {
        defer { app.stop() }
        let before = try runtime.entries()
        let id = UUID()
        let target = runtime.identity
        let prefix =
          #""id":"\#(id)","runID":"\#(target.runID)","pid":\#(target.pid),"bundleID":"\#(target.bundleID)""#
        let reply = try await runtime.send(Data("{\(prefix),\(body)}".utf8), id: id)
        #expect(reply.id == id && reply.target == target)
        guard case .failure(let failure) = reply.outcome else {
          throw RuntimeTestError("The runtime accepted \(body)")
        }
        #expect(!failure.message.isEmpty)
        let after = try runtime.entries()
        #expect(after.contains { $0.event == "control.rejected" && $0.requestID == id.uuidString })
        for event in ["faults.configured", "push.received"] {
          #expect(after.count { $0.event == event } == before.count { $0.event == event })
        }
      }

      @Test(arguments: [false, true])
      func aRequestForAnotherProcessOrFileIsDiscardedUnanswered(filenameMismatch: Bool)
        async throws
      {
        defer { app.stop() }
        let id = UUID()
        let bodyID = filenameMismatch ? UUID() : id
        let bytes =
          filenameMismatch
          ? try request(bodyID, .status)
          : Data(
            String(decoding: try request(id, .status), as: UTF8.self)
              .replacingOccurrences(
                of: "\"pid\":\(runtime.identity.pid)", with: "\"pid\":\(runtime.identity.pid + 1)"
              ).utf8)
        try runtime.stage(bytes, id: id)
        let file = requests.appending(path: "\(id.uuidString).json")
        try await runtime.until("the runtime to discard the request") {
          FileManager.default.fileExists(atPath: file.path()) ? nil : true
        }
        for unanswered in [id, bodyID] {
          #expect(
            !FileManager.default.fileExists(
              atPath: responses.appending(path: "\(unanswered.uuidString).json").path()))
        }
      }

      @Test func aFailedResponseWriteIsRetriedFromTheSameRequest() async throws {
        defer { app.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: responses.path())
        let mode = try #require(attributes[.posixPermissions] as? NSNumber).uint16Value
        #expect(chmod(responses.path(), 0o500) == 0)
        defer { _ = chmod(responses.path(), mode_t(mode)) }
        let id = UUID()
        let retry = try request(id, .status)
        let cursor = try runtime.cursor()
        try runtime.stage(retry, id: id)
        let failed = try await runtime.entry("the failed response write", after: cursor) {
          $0.event == "control.responseWriteFailed" && $0.commandID == id.uuidString
        }
        #expect(
          FileManager.default.fileExists(
            atPath: requests.appending(path: "\(id.uuidString).json").path()))
        #expect(chmod(responses.path(), mode_t(mode)) == 0)
        let reply = try await runtime.send(retry, id: id)
        guard case .status(let snapshot) = try reply.get() else {
          throw RuntimeTestError("Expected the cached status")
        }
        #expect(snapshot.sequence + 1 == failed.sequence)
      }

      @Test func callControlsReturnTheActionsTheyDelivered() async throws {
        defer { app.stop() }
        try await runtime.clearSettings()
        let known = Set(try await runtime.status().calls.map(\.state.uuid))
        let push = try await runtime.send(
          .push(PushPayload(fields: ["operation": .string("incoming")]), mustReport: false))
        #expect(try push.get() == .push(pushID: push.id))
        let call = try await runtime.until("the pushed call") {
          try await runtime.status().calls.map(\.state.uuid).first { !known.contains($0) }
        }
        let status = try await runtime.status()
        let incoming = try #require(status.calls.first { $0.state.uuid == call })
        #expect(incoming.state.ringing && incoming.relationship == .callkit(group: call))
        #expect(!status.providerConfigurations.isEmpty)
        let cursor = try runtime.cursor()
        for control in [ControlRequest.CallControl.answer(call), .end(call)] {
          let ids = try await runtime.perform(control)
          try await runtime.until("the actions to settle") {
            let settled = Set(
              try runtime.entries(after: cursor).filter { $0.event == "action.settled" }
                .compactMap(\.actionID))
            return ids.allSatisfy { settled.contains($0.uuidString) } ? true : nil
          }
        }
        try await runtime.end([call])
        guard case .reset(let provider) = try await runtime.control(.reset) else {
          throw RuntimeTestError("Expected the provider reset")
        }
        #expect(!provider.isEmpty && UUID(uuidString: provider) == nil)
      }
    }
  }
#endif
