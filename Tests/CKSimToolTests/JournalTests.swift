#if os(macOS)
  import CKSimProtocol
  import Foundation
  import Synchronization
  import Testing

  @testable import CKSimTool

  /// Reading a run's journal, `cksim watch`, and the Inspector's bridge.
  struct JournalTests {
    @Test func theJournalIsReadIncrementallyAndChecked() throws {
      let scratch = try Scratch()
      let app = try FakeApp(in: scratch.url)
      var journal = try Journal(channel: app.channel, bundle: bundle)
      #expect(try journal.read().isEmpty)
      try app.append([["event": "runtime.installed"], ["event": "push.received"]])
      #expect(try journal.read().map(\.sequence) == [1, 2])
      // A partial line waits for the rest of it.
      let file = app.mailbox.appending(path: "events.jsonl")
      let handle = try FileHandle(forWritingTo: file)
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(#"{"schemaVersion":1"#.utf8))
      try handle.close()
      #expect(try journal.read().isEmpty)

      var gap = try Journal(channel: app.channel, bundle: bundle)
      let corrupted = try String(contentsOf: file, encoding: .utf8)
        .replacingOccurrences(of: #""sequence":2"#, with: #""sequence":3"#)
      try Data(corrupted.utf8).write(to: file)
      #expect(throws: CKSimError("Unsupported or inconsistent runtime event channel.")) {
        try gap.read()
      }
      try Data().write(to: file)
      #expect(throws: CKSimError("Runtime journal was truncated; reconnect to the run.")) {
        try journal.read()
      }
    }

    @Test func aChangedSessionIsReported() throws {
      let scratch = try Scratch()
      let app = try FakeApp(in: scratch.url)
      var journal = try Journal(channel: app.channel, bundle: bundle)
      try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 1, "bundleID": bundle, "pid": 999, "runID": "next",
        "profile": "ios-27.0", "controlTransport": "directory-watch-v1",
      ]).write(to: app.channel.appending(path: "session.json"))
      #expect(throws: CKSimError("Runtime session changed; reconnect to the new run.")) {
        try journal.read()
      }
    }

    @Test func theTimelineSummarizesEachEntry() {
      #expect(
        timelineLine([
          "sequence": 7, "t_ms": 1234, "event": "action.settled", "kind": "answer",
          "origin": "system", "callUUID": "C1", "deadlineSeconds": 60.0, "apiKind": "callkit",
          "fulfilled": true, "latencyMS": 120.25,
        ])
          == "     7     1.234s  action.settled            answer · system · C1 · budget 60s (callkit) · fulfilled in 120.2ms"
      )
      #expect(
        timelineLine([
          "sequence": 12, "t_ms": 5, "event": "call.changed", "uuid": "U", "callerName": "A\u{7}",
          "held": true,
        ]) == "    12     0.005s  call.changed              A? · U · held")
    }

    @Test func watchPrintsTheJournalAsWrittenOrAsATimeline() async throws {
      let scratch = try Scratch()
      let app = try FakeApp(in: scratch.url)
      try app.append([["event": "runtime.installed"], ["event": "push.received", "pushID": "P"]])
      for json in [true, false] {
        let printed = Mutex([String]())
        var tool = Tool()
        tool.write = { line in printed.withLock { $0.append(line) } }
        try await Tool.$current.withValue(tool) {
          try await watch(
            channel: app.channel, bundle: bundle, json: json, after: 1,
            duration: .milliseconds(150))
        }
        let lines = printed.withLock { $0 }
        #expect(lines.count == 1)
        if json {
          let entry = try #require(
            try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
          #expect(entry["sequence"] as? Int == 2 && entry["pushID"] as? String == "P")
        } else {
          #expect(lines[0].contains("push.received"))
        }
      }
    }

    @Test func theBridgeServesTheJournalAndReplaysAFailedBatch() async throws {
      let scratch = try Scratch()
      let app = try FakeApp(in: scratch.url)
      let target = Target(
        simctl: FakeSimulator().simctl, device: device, bundle: bundle, appContainer: app.container)
      let bridge = try InspectorBridge(target: target, timeout: .seconds(2))
      try app.append([["event": "runtime.installed"]])
      let first = try await bridge.events(after: 0)
      #expect(try await bridge.events(after: 0) == first, "The same batch again")
      let batch = try #require(try JSONSerialization.jsonObject(with: first) as? [String: Any])
      #expect(batch["cursor"] as? Int == 1 && (batch["events"] as? [Any])?.count == 1)
      await #expect(throws: CKSimError.self) { try await bridge.events(after: 5) }
    }

    @Test func theBridgeTranslatesTheInspectorsControls() throws {
      let a = UUID().uuidString
      let b = UUID().uuidString
      let c = UUID().uuidString
      let valid: [([String: Any], ControlRequest.Operation)] = [
        (["operation": "answer", "callUUID": a], .call(.answer(UUID(uuidString: a)!))),
        (
          ["operation": "hold", "callUUID": a, "held": "true", "applicationRequest": "true"],
          .call(.hold(UUID(uuidString: a)!, held: true, origin: .application))
        ),
        (
          ["operation": "merge", "callUUID": a, "groupWithCallUUID": b],
          .call(.merge(UUID(uuidString: a)!, with: UUID(uuidString: b)!, origin: .system))
        ),
        (
          [
            "operation": "end-held-and-accept", "callUUID": a, "activeCallUUID": b,
            "heldCallUUID": c,
          ],
          .call(
            .endHeldAndAccept(
              UUID(uuidString: a)!, active: UUID(uuidString: b)!, held: UUID(uuidString: c)!))
        ),
        (
          ["operation": "incoming-filter", "reason": "do-not-disturb"],
          .incomingFilter(.doNotDisturb)
        ),
        (["operation": "faults", "incomingErrorCode": "4"], .faults([.incomingErrorCode(4)])),
      ]
      for (command, operation) in valid {
        #expect(try InspectorBridge.operation(command) == operation)
      }
      let invalid: [[String: Any]] = [
        ["operation": "status"], ["operation": "faults", "incomingErrorCode": "3"],
        ["operation": "incoming-filter", "reason": "block-list"],
        ["operation": "incoming-filter", "reason": "none", "callUUID": a],
        ["operation": "answer", "callUUID": a, "applicationRequest": "true"],
        ["operation": "hold", "callUUID": a, "held": "yes"], ["operation": "answer"],
        ["operation": "answer", "callUUID": 3], ["operation": "answer", "callUUID": "not-a-uuid"],
        [
          "operation": "end-held-and-accept", "callUUID": a, "activeCallUUID": a, "heldCallUUID": b,
        ],
      ]
      for command in invalid {
        #expect(throws: CKSimError.self, "\(command)") { try InspectorBridge.operation(command) }
      }
    }

    @Test func theServerNeedsTheTokenAndForwardsControls() async throws {
      let scratch = try Scratch()
      let app = try FakeApp(in: scratch.url)
      try app.append([["event": "runtime.installed"]])
      let responder = app.respond()
      defer { responder.cancel() }
      let target = Target(
        simctl: FakeSimulator().simctl, device: device, bundle: bundle, appContainer: app.container)
      let bridge = try InspectorBridge(target: target, timeout: .seconds(5))
      try await bridge.checkTarget()
      let server = try await InspectorServer(bridge: bridge)
      defer { server.stop() }
      let session = URLSession(configuration: .ephemeral)
      func request(_ path: String, token: String? = nil, body: [String: String]? = nil)
        async throws -> (Int, Data)
      {
        var request = URLRequest(url: try #require(URL(string: server.url + path)))
        request.setValue("Bearer " + (token ?? server.token), forHTTPHeaderField: "Authorization")
        if let body {
          request.httpMethod = "POST"
          request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
      }
      #expect(try await request("/events?after=0", token: "wrong").0 == 401)
      let (status, events) = try await request("/events?after=0")
      #expect(status == 200)
      let batch = try #require(try JSONSerialization.jsonObject(with: events) as? [String: Any])
      #expect(batch["cursor"] as? Int == 1)
      let (accepted, response) = try await request(
        "/command", body: ["operation": "answer", "callUUID": call.uuidString])
      #expect(accepted == 200)
      #expect(
        try JSONDecoder().decode(ControlResponse.self, from: response).target.runID == FakeApp.runID
      )
      #expect(try await request("/command", body: ["operation": "status"]).0 == 409)
      #expect(try await request("/elsewhere").0 == 404)
    }
  }
#endif
