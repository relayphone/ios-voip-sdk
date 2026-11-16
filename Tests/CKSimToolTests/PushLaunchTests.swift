#if os(macOS)
  import Foundation
  import CKSimProtocol
  import Testing
  import Synchronization
  import VoIPTesting

  @testable import CKSimTool

  /// `cksim push --launch`: staging a push for a stopped app.
  struct PushLaunchTests {
    private let scratch: Scratch
    private let app: FakeApp
    private let launch: PushLaunch

    init() throws {
      scratch = try Scratch()
      app = try FakeApp(in: scratch.url)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: app.channel.path())
      let payload = scratch.url.appending(path: "payload.json")
      try Data(#"{"aps":{},"callId":"launch-1"}"#.utf8).write(to: payload)
      launch = PushLaunch(
        target: Target(simctl: FakeSimulator().simctl, device: device, bundle: bundle),
        runID: "launch-run", mustReport: true, payloadFile: payload,
        receipt: scratch.url.appending(path: "launch-receipt.json"))
    }

    private static let stopped = Data(
      "PID\tStatus\tLabel\n-\t0\tUIKitApplication:\(bundle)[1a2b]\n".utf8)

    @Test func preparationPinsThePlanWithoutClaimingLaunchWasRequested() async throws {
      let simulator = FakeSimulator()
      simulator.state.withLock { $0.containers[bundle] = app.container }
      let result = try await PushLaunch(
        target: Target(simctl: simulator.simctl, device: device, bundle: bundle),
        runID: launch.runID, mustReport: true, payloadFile: launch.payloadFile,
        receipt: launch.receipt
      ).prepare()
      let prepared = try #require(result)
      #expect(
        prepared.arguments == ["/usr/bin/xcrun", "simctl", "launch", "--console", device, bundle])
      let identity = try ProcessLifecycleIdentity(
        simulatorID: UUID(uuidString: device)!, bundleID: bundle, runID: launch.runID)
      #expect(prepared.envelope.runID == identity.runID)
      #expect(!exists(app.channel.appending(path: "process/launch-run")))
      #expect(!simulator.calls.contains { $0.first == "launch" })
      #expect(throws: CKSimError.self) {
        try launch.stage(container: app.container, serviceTable: Self.stopped)
      }
    }

    @Test func droppedColdDuplicatesRetainEveryCopyWithoutLaunching() async throws {
      let simulator = FakeSimulator()
      simulator.state.withLock { $0.containers[bundle] = app.container }
      let request = PushLaunch(
        target: Target(simctl: simulator.simctl, device: device, bundle: bundle),
        runID: launch.runID, mustReport: true, payloadFile: launch.payloadFile,
        receipt: launch.receipt,
        delivery: try PushDeliveryFaults(drop: true, duplicate: 2, spacingMS: 500))
      let prepared = try await request.prepare()
      #expect(prepared == nil)
      let identity = try ProcessLifecycleIdentity(
        simulatorID: UUID(uuidString: device)!, bundleID: bundle, runID: launch.runID)
      let rows = try ProcessJournal(channel: app.channel, identity: identity).read().map {
        try JSONDecoder().decode(ProcessLifecycleRecord.self, from: $0.line)
      }
      #expect(rows.count == 3 && rows.allSatisfy { $0.event == .dropped && $0.pid == nil })
      #expect(
        Set(rows.compactMap(\.pushID)).count == 3 && Set(rows.compactMap(\.requestID)).count == 1)
      #expect(!exists(app.channel.appending(path: "push-launch.json")))
      #expect(!simulator.calls.contains { $0.first == "launch" })
    }

    @Test func coldLaunchDuplicatesAreStagedAsOneStableNativePlan()
      async throws
    {
      let simulator = FakeSimulator()
      simulator.state.withLock { $0.containers[bundle] = app.container }
      let request = PushLaunch(
        target: Target(simctl: simulator.simctl, device: device, bundle: bundle),
        runID: launch.runID, mustReport: true, payloadFile: launch.payloadFile,
        receipt: launch.receipt, delivery: try PushDeliveryFaults(duplicate: 2, spacingMS: 500))
      let result = try await request.prepare()
      let prepared = try #require(result)
      let staged = try JSONDecoder().decode(
        PushLaunchEnvelope.self,
        from: Data(contentsOf: app.channel.appending(path: "push-launch.json")))
      #expect(staged == prepared.envelope)
      #expect(staged.delivery.duplicate == 2 && staged.deliveryIDs.count == 3)
      #expect(Set(staged.deliveryIDs).count == 3 && staged.deliveryIDs.first == staged.id)
      #expect(!simulator.calls.contains { $0.first == "launch" })
    }

    @Test func aStagedPushHasItsEnvelopeAndReceipt() throws {
      let before = Int(Date().timeIntervalSince1970 * 1000)
      let (arguments, environment) = try launch.stage(
        container: app.container, serviceTable: Self.stopped)
      #expect(arguments == ["/usr/bin/xcrun", "simctl", "launch", "--console", device, bundle])
      #expect(environment["SIMCTL_CHILD_CKSIM_RUN_ID"] == "launch-run")
      #expect(environment["SIMCTL_CHILD_CKSIM_ENABLED"] == nil)
      let file = app.channel.appending(path: "push-launch.json")
      let data = try Data(contentsOf: file)
      let envelope = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(
        Set(envelope.keys) == [
          "schemaVersion", "id", "runID", "bundleID", "createdAtMS", "expiresAtMS", "mustReport",
          "payload", "delivery", "deliveryIDs",
        ])
      let created = try #require(envelope["createdAtMS"] as? Int)
      #expect(created >= before && envelope["expiresAtMS"] as? Int == created + 30_000)
      #expect(
        envelope["runID"] as? String == "launch-run" && envelope["mustReport"] as? Bool == true)
      let typed = try JSONDecoder().decode(PushLaunchEnvelope.self, from: data)
      #expect(typed.schemaVersion == .deliveryPlan && typed.delivery == .none)
      #expect(typed.deliveryIDs == [typed.id])
      let mode = try FileManager.default.attributesOfItem(atPath: file.path())[.posixPermissions]
      #expect((mode as? NSNumber)?.intValue == 0o600)
      let receipt = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: launch.receipt)) as? [String: Any])
      #expect(receipt["envelopeSHA256"] as? String == sha256(data))
      #expect(receipt["pushID"] as? String == envelope["id"] as? String)
      #expect(receipt["appServiceAbsent"] as? Bool == true && receipt["mode"] as? Int == 0o600)
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: app.channel.path()).allSatisfy {
          !$0.hasPrefix(".push-launch-")
        })
      #expect(throws: CKSimError.self, "A pending push is never replaced") {
        try PushLaunch(
          target: launch.target, runID: "launch-run", mustReport: true,
          payloadFile: launch.payloadFile, receipt: scratch.url.appending(path: "second.json")
        ).stage(container: app.container, serviceTable: Self.stopped)
      }
    }

    @Test(arguments: [
      ("", "Invalid launchctl service table"),
      ("PID\tStatus\tLabel\n", "Invalid launchctl service table"),
      ("PID\tStatus\tLabel\ninvalid\t0\tlabel\n", "Invalid launchctl service table"),
      ("PID\tStatus\tLabel\n812\t0\tUIKitApplication:\(bundle)[1a2b]\n", "requires a stopped app"),
    ])
    func aRunningAppOrAnUnreadableTableIsRefused(table: String, message: String) throws {
      do {
        _ = try launch.stage(container: app.container, serviceTable: Data(table.utf8))
        Issue.record("The push was staged")
      } catch let error as CKSimError {
        #expect(error.description.contains(message))
      }
      #expect(!FileManager.default.fileExists(atPath: launch.receipt.path()))
    }

    @Test func delayDoesNotStageOrQueryBeforeItsAcceptedDeadline() async throws {
      let clock = TestClock()
      let simulator = FakeSimulator()
      simulator.state.withLock { $0.containers[bundle] = app.container }
      let delayed = PushLaunch(
        target: Target(simctl: simulator.simctl, device: device, bundle: bundle),
        runID: launch.runID, mustReport: true, payloadFile: launch.payloadFile,
        receipt: launch.receipt, delivery: try PushDeliveryFaults(delayMS: 1000))
      let request = delayed
      let task = Task { try await request.prepare(clock: clock) }
      try await clock.waitForSleepers()
      #expect(simulator.calls.isEmpty)
      #expect(!FileManager.default.fileExists(atPath: launch.receipt.path))
      #expect(
        !FileManager.default.fileExists(
          atPath: app.channel.appending(path: "push-launch.json").path))
      clock.advance(by: .milliseconds(999))
      #expect(simulator.calls.isEmpty)
      // Editing the source after acceptance must not change the scheduled payload.
      try Data("[]".utf8).write(to: launch.payloadFile)
      clock.advance(by: .milliseconds(1))
      #expect(try await task.value != nil)
      let envelope = try JSONDecoder().decode(
        PushLaunchEnvelope.self,
        from: Data(contentsOf: app.channel.appending(path: "push-launch.json")))
      #expect(envelope.delivery.delayMS == 1000)
      #expect(envelope.payload.fields["callId"] == .string("launch-1"))
    }

    @Test func appStartedDuringDelayCannotBeRelaunched() async throws {
      let clock = TestClock()
      let simulator = FakeSimulator()
      simulator.state.withLock { $0.containers[bundle] = app.container }
      let request = PushLaunch(
        target: Target(simctl: simulator.simctl, device: device, bundle: bundle),
        runID: launch.runID, mustReport: true, payloadFile: launch.payloadFile,
        receipt: launch.receipt, delivery: try PushDeliveryFaults(delayMS: 1000))
      let task = Task { try await request.prepare(clock: clock) }
      try await clock.waitForSleepers()
      simulator.state.withLock {
        $0.serviceTable = "PID\tStatus\tLabel\n812\t0\tUIKitApplication:\(bundle)[1a2b]\n"
      }
      clock.advance(by: .seconds(1))
      await #expect(throws: CKSimError.self) { try await task.value }
      #expect(!FileManager.default.fileExists(atPath: launch.receipt.path))
      #expect(
        !FileManager.default.fileExists(
          atPath: app.channel.appending(path: "push-launch.json").path))
    }

    @Test func droppedRequestHasOnlyAHostTerminalOutcome() async throws {
      let simulator = FakeSimulator()
      simulator.state.withLock { $0.containers[bundle] = app.container }
      let dropped = PushLaunch(
        target: Target(simctl: simulator.simctl, device: device, bundle: bundle),
        runID: launch.runID, mustReport: true, payloadFile: launch.payloadFile,
        receipt: launch.receipt, delivery: try PushDeliveryFaults(drop: true))
      #expect(try await dropped.prepare() == nil)
      #expect(simulator.calls.count == 1 && simulator.calls.first?.first == "get_app_container")
      #expect(
        !FileManager.default.fileExists(
          atPath: app.channel.appending(path: "push-launch.json").path))
      let identity = try ProcessLifecycleIdentity(
        simulatorID: UUID(uuidString: device)!, bundleID: bundle, runID: launch.runID)
      let rows = try ProcessJournal(channel: app.channel, identity: identity).read()
      #expect(rows.count == 1)
      let row = try JSONDecoder().decode(
        ProcessLifecycleRecord.self, from: #require(rows.first).line)
      #expect(
        row.event == .dropped && row.pid == nil && row.requestID == row.pushID && row.pushID != nil)
      #expect(throws: CKSimError.self) {
        try launch.stage(container: app.container, serviceTable: Self.stopped)
      }
    }

    @Test func cancelledDelayCannotLeaveAStagedEnvelope() async throws {
      let clock = TestClock()
      var delayed = launch
      delayed.delivery = try PushDeliveryFaults(delayMS: 1000)
      let request = delayed
      let task = Task { try await request.prepare(clock: clock) }
      try await clock.waitForSleepers()
      task.cancel()
      await #expect(throws: CancellationError.self) { try await task.value }
      #expect(!FileManager.default.fileExists(atPath: launch.receipt.path))
      #expect(
        !FileManager.default.fileExists(
          atPath: app.channel.appending(path: "push-launch.json").path))
    }

    @Test func invalidPayloadIsRejectedBeforeDelayOrDrop() async throws {
      try Data("[]".utf8).write(to: launch.payloadFile)
      var dropped = launch
      dropped.delivery = try PushDeliveryFaults(delayMS: 120000, drop: true)
      await #expect(throws: (any Error).self) { try await dropped.prepare(clock: TestClock()) }
      #expect(!FileManager.default.fileExists(atPath: launch.receipt.path))
    }

    @Test(arguments: [false, true])
    func cancellationInSimulatorQueryCannotStageOrDrop(drop: Bool) async throws {
      let simulator = FakeSimulator()
      simulator.state.withLock { $0.containers[bundle] = app.container }
      let simctl = Simctl { arguments, environment, limit in
        let output = try simulator.simctl.run(arguments, environment, limit)
        if arguments.first == (drop ? "get_app_container" : "spawn") {
          withUnsafeCurrentTask { $0?.cancel() }
        }
        return output
      }
      let request = PushLaunch(
        target: Target(simctl: simctl, device: device, bundle: bundle),
        runID: launch.runID, mustReport: true, payloadFile: launch.payloadFile,
        receipt: launch.receipt, delivery: try PushDeliveryFaults(drop: drop))
      let task = Task { try await request.prepare() }
      await #expect(throws: CancellationError.self) { try await task.value }
      #expect(!FileManager.default.fileExists(atPath: launch.receipt.path))
      #expect(
        !FileManager.default.fileExists(
          atPath: app.channel.appending(path: "process/launch-run").path))
      #expect(
        !FileManager.default.fileExists(
          atPath: app.channel.appending(path: "push-launch.json").path))
    }

    @Test func anUnsafeDirectoryIsRefused() throws {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: app.channel.path())
      #expect(throws: CKSimError("Unsafe push launch directory.")) {
        try launch.stage(container: app.container, serviceTable: Self.stopped)
      }
    }

    @Test(arguments: ["launch-run", "process/launch-run"])
    func aPreviousInvocationCannotBeReused(path: String) throws {
      try FileManager.default.createDirectory(
        at: app.channel.appending(path: path), withIntermediateDirectories: true)
      #expect(throws: CKSimError.self) {
        try launch.stage(container: app.container, serviceTable: Self.stopped)
      }
      #expect(!FileManager.default.fileExists(atPath: launch.receipt.path))
      #expect(
        !FileManager.default.fileExists(
          atPath: app.channel.appending(path: "push-launch.json").path))
    }
  }
#endif
