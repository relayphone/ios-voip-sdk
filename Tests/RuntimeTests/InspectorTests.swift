#if os(iOS) && targetEnvironment(simulator)
  import CKSimProtocol
  import Foundation
  import Testing

  @testable import CKSimInspector

  /// A bridge to this process's runtime, standing in for `cksim inspect`: it serves the run's
  /// journal and publishes the Inspector's controls to the runtime's mailbox.
  @MainActor
  final class RuntimeBridge: InspectorBridge {
    private let runtime: Runtime

    init(_ runtime: Runtime) { self.runtime = runtime }

    func events(after cursor: Int) async throws -> Data {
      let session = try JSONSerialization.jsonObject(
        with: Data(contentsOf: runtime.root.appending(path: "session.json")))
      let bytes = try Data(contentsOf: runtime.journal)
      var lines = bytes.split(separator: 10)
      if bytes.last != 10, !lines.isEmpty { lines.removeLast() }
      let events = try lines.dropFirst(cursor).map {
        try JSONSerialization.jsonObject(with: Data($0))
      }
      return try JSONSerialization.data(withJSONObject: [
        "session": session, "events": events, "cursor": lines.count,
      ])
    }

    func command(_ body: [String: String]) async throws -> Data {
      let request = try ControlRequest(
        id: UUID(), target: runtime.identity, operation: Self.operation(body))
      return try await runtime.publish(JSONEncoder().encode(request), id: request.id)
    }

    /// The control that the Inspector's command names.
    static func operation(_ body: [String: String]) throws -> ControlRequest.Operation {
      func call(_ key: String) throws -> UUID {
        try #require(body[key].flatMap(UUID.init(uuidString:)), "\(key)")
      }
      let origin: ControlRequest.Origin =
        body["applicationRequest"] == "true" ? .application : .system
      switch body["operation"] {
      case "incoming-filter":
        return .incomingFilter(
          try #require(body["reason"].flatMap(ControlRequest.FilterReason.init)))
      case "faults":
        return .faults([
          .incomingErrorCode(try #require(body["incomingErrorCode"].flatMap(Int.init)))
        ])
      case "answer": return .call(.answer(try call("callUUID")))
      case "decline": return .call(.decline(try call("callUUID")))
      case "end": return .call(.end(try call("callUUID")))
      case "hold":
        return .call(.hold(try call("callUUID"), held: body["held"] == "true", origin: origin))
      case "merge":
        return .call(
          .merge(try call("callUUID"), with: try call("groupWithCallUUID"), origin: origin))
      case "unmerge": return .call(.unmerge(try call("callUUID"), origin: origin))
      case "hold-and-accept":
        return .call(.holdAndAccept(try call("callUUID"), active: try call("activeCallUUID")))
      case "end-and-accept":
        return .call(.endAndAccept(try call("callUUID"), active: try call("activeCallUUID")))
      case "end-held-and-accept":
        return .call(
          .endHeldAndAccept(
            try call("callUUID"), active: try call("activeCallUUID"), held: try call("heldCallUUID")
          ))
      default: throw RuntimeTestError("Unknown Inspector command \(body)")
      }
    }
  }

  extension RuntimeSuites {
    /// The Inspector's model on the runtime's real journal, controlling real calls.
    @Suite @MainActor struct Inspector {
      /// Starts a model on the runtime and waits for it to connect.
      private func inspect(_ runtime: Runtime) async throws -> (InspectorModel, Task<Void, Never>) {
        let model = InspectorModel(bridge: RuntimeBridge(runtime), pollInterval: .milliseconds(20))
        let task = Task { await model.follow() }
        try await runtime.until("the Inspector to connect") { model.online ? true : nil }
        return (model, task)
      }

      /// Submits a control and waits until the journal confirms it.
      private func submit(
        _ model: InspectorModel, _ runtime: Runtime, _ description: String,
        _ control: () -> Void
      ) async throws {
        #expect(model.online && !model.busy && model.pending.isEmpty, "Ready for \(description)")
        control()
        #expect(model.busy, "The Inspector submitted \(description)")
        try await runtime.until(description) {
          !model.busy && model.pending.isEmpty ? true : nil
        }
        #expect(model.commandError == nil, "\(description)")
      }

      @Test func theInspectorFollowsAndAnswersACallKitCall() async throws {
        let runtime = try Runtime.shared()
        let app = CallKitApp()
        defer { app.stop() }
        try await runtime.clearSettings()
        let (model, task) = try await inspect(runtime)
        defer { task.cancel() }
        let call = UUID()
        try await runtime.push([
          "operation": .string("incoming"), "callUUID": .string(call.uuidString),
        ])
        let incoming = try await runtime.until("the Inspector to show the incoming call") {
          model.incoming?.uuid == call.uuidString ? model.incoming : nil
        }
        #expect(incoming.caller == "Alex Morgan" && incoming.status == "Incoming call")
        try await submit(model, runtime, "the answer") { model.send("answer", call: incoming) }
        try await runtime.until("the Inspector to show the call connected with audio") {
          model.conversations[call.uuidString]?.status == "Connected" && model.audioActive
            ? true : nil
        }
        #expect(
          model.timeline.contains {
            $0.event == "action.settled" && $0.kind == "answer" && $0.fulfilled == true
              && $0.callUUID == call.uuidString
          })
        let answerAudio = try #require(model.timingReferences.first { $0.id == "answerAudio" })
        #expect(answerAudio.actualMS != nil, "The Inspector measures answer to audio")
        let connected = try #require(model.conversations[call.uuidString])
        try await submit(model, runtime, "the end") { model.send("end", call: connected) }
        try await runtime.until("the Inspector to show the call ended") {
          model.conversations[call.uuidString]?.ended == true && !model.audioActive ? true : nil
        }
        try await runtime.end([call])
      }

      @Test func theInspectorConfiguresFiltersAndTheInjectedError() async throws {
        let runtime = try Runtime.shared()
        try await runtime.clearSettings()
        let (model, task) = try await inspect(runtime)
        defer { task.cancel() }
        for filter in [InspectorIncomingFilter.doNotDisturb, .none] {
          model.configureIncomingFilter(filter)
          try await runtime.until("the filter \(filter)") {
            !model.busy && model.incomingFilter == filter ? true : nil
          }
          #expect(model.commandError == nil)
          #expect(try await runtime.status().incomingFilter.reason.rawValue == filter.rawValue)
        }
        for code in [4, 0] {
          model.configureIncomingError(code)
          try await runtime.until("the injected error \(code)") {
            !model.busy && model.incomingErrorCode == code ? true : nil
          }
          #expect(model.commandError == nil)
          #expect(try await runtime.status().incomingErrorCode == code)
        }
      }

      @Test func theInspectorControlsLiveCommunicationKitCalls() async throws {
        let session = try await LCKSession()
        let runtime = session.runtime
        try await session.pair()
        _ = try await session.composite()
        try await session.expect(["A": "paused", "B": "joined"])
        let (model, task) = try await inspect(runtime)
        defer { task.cancel() }
        let a = session.app.id("A").uuidString
        let b = session.app.id("B").uuidString
        try await runtime.until("both calls in the Inspector") {
          model.conversations[a]?.held == true && model.conversations[b]?.held == false ? true : nil
        }
        let callA = try #require(model.conversations[a])
        let callB = try #require(model.conversations[b])

        // The Inspector's ordinary controls act as the system, which resumes A without ending B.
        try await submit(model, runtime, "the system's resume of A") {
          model.send("hold", call: callA, held: false)
        }
        try await runtime.until("A to resume") {
          model.conversations[a]?.held == false ? true : nil
        }
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.conversations[b]?.ended != true, "The system's resume doesn't end B")
        try await submit(model, runtime, "the system's pause of A") {
          model.send("hold", call: callA, held: true)
        }
        try await runtime.until("A to pause") { model.conversations[a]?.held == true ? true : nil }

        try await submit(model, runtime, "the app's merge of B into A") {
          model.send("merge", call: callB, groupTarget: callA, applicationRequest: true)
        }
        #expect(model.conversations[a]?.held == true && model.conversations[b]?.held == false)
        try await submit(model, runtime, "the app's unmerge of B") {
          model.send("unmerge", call: callB, applicationRequest: true)
        }
        #expect(model.conversations[a]?.held == true && model.conversations[b]?.held == false)
        try await submit(model, runtime, "the app's pause of B") {
          model.send("hold", call: callB, held: true, applicationRequest: true)
        }
        try await runtime.until("B to pause") { model.conversations[b]?.held == true ? true : nil }
        try await submit(model, runtime, "the app's resume of B") {
          model.send("hold", call: callB, held: false, applicationRequest: true)
        }
        try await runtime.until("B to resume") {
          model.conversations[b]?.held == false ? true : nil
        }
        // The app's own resume of A ends B, as the measured device does.
        try await submit(model, runtime, "the app's resume of A") {
          model.send("hold", call: callA, held: false, applicationRequest: true)
        }
        try await runtime.until("A to join and B to end") {
          model.conversations[a]?.connected == true && model.conversations[a]?.held == false
            && model.conversations[b]?.ended == true ? true : nil
        }
        try await session.finish()
      }
    }
  }
#endif
