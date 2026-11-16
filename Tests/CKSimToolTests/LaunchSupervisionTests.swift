#if os(macOS)
  import CKSimProtocol
  import Foundation
  import Synchronization
  import Testing
  @testable import CKSimTool

  struct LaunchSupervisionTests {
    let scratch: Scratch
    let app: FakeApp
    init() throws {
      scratch = try Scratch()
      app = try FakeApp(in: scratch.url)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: app.channel.path)
    }
    func envelope() throws -> PushLaunchEnvelope {
      let id = UUID()
      return try PushLaunchEnvelope(
        id: id, runID: FakeApp.runID, bundleID: bundle,
        createdAtMS: 0, expiresAtMS: 30_000, mustReport: true,
        payload: JSONDecoder().decode(PushPayload.self, from: Data("{}".utf8)),
        delivery: PushDeliveryFaults(delayMS: 0, drop: false, duplicate: 2, spacingMS: 1000),
        deliveryIDs: [id, UUID(), UUID()])
    }
    func identity() throws -> ProcessLifecycleIdentity {
      try .init(simulatorID: UUID(uuidString: device)!, bundleID: bundle, runID: FakeApp.runID)
    }
    func rows() throws -> [ProcessLifecycleRecord] {
      try ProcessJournal(channel: app.channel, identity: identity()).read().filter {
        !$0.producer.hasPrefix("runtime-")
      }.map {
        try JSONDecoder().decode(ProcessLifecycleRecord.self, from: $0.line)
      }.filter { $0.event != .launchScheduled }
    }
    func target(failLaunch: Bool = false, replaced: Bool = false) -> Target {
      Target(
        simctl: Simctl { arguments, _, _ in
          if arguments.first == "get_app_container" {
            return ProcessOutput(standardOutput: Data(app.container.path.utf8))
          }
          if arguments.first == "launch" {
            return ProcessOutput(
              status: failLaunch ? 1 : 0, standardOutput: Data("\(bundle): \(FakeApp.pid)\n".utf8))
          }
          return ProcessOutput(
            standardOutput: Data(
              "PID Status Label\n\(replaced ? String(FakeApp.pid + 1) : "-") 0 UIKitApplication:\(bundle)[test]\n"
                .utf8))
        }, device: device, bundle: bundle)
    }
    @Test func exitBeforeRuntimeSchedulingRetainsEveryCopyWithoutReplaying() async throws {
      let plan = try envelope()
      try await ProcessLifecycle.supervise(
        target: target(), container: app.container, envelope: plan, environment: [:],
        hasExited: { _ in true })
      let records = try rows()
      #expect(records.contains { $0.event == .exited })
      #expect(records.filter { $0.event == .cancelled }.compactMap(\.pushID) == plan.deliveryIDs)
      #expect(
        records.filter { $0.event != .launchRequested }.allSatisfy {
          $0.cause == .unknown && $0.pid == FakeApp.pid
        })
      #expect(
        try ProcessJournal(channel: app.channel, identity: identity()).pendingLaunchDeliveries(
          plan, pid: FakeApp.pid
        ).isEmpty)
    }
    @Test func receivedCopiesAndPriorCancellationsAreNotCancelledAgain() async throws {
      let plan = try envelope()
      let journal = try ProcessLifecycle(channel: app.channel, identity: identity())
      try await journal.record(
        .cancelled, pid: FakeApp.pid, requestID: plan.id, pushID: plan.deliveryIDs[1])
      try app.append([["event": "push.received", "pushID": plan.deliveryIDs[0].uuidString]])
      try await ProcessLifecycle.supervise(
        target: target(), container: app.container, envelope: plan, environment: [:],
        hasExited: { _ in true })
      #expect(
        try rows().filter { $0.event == .cancelled }.compactMap(\.pushID)
          == Array(plan.deliveryIDs.dropFirst()))
    }
    @Test func launchFailureIsDistinctFromConfirmedExit() async throws {
      await #expect(throws: CKSimError.self) {
        try await ProcessLifecycle.supervise(
          target: target(failLaunch: true), container: app.container, envelope: envelope(),
          environment: [:], hasExited: { _ in true })
      }
      #expect(try rows().map(\.event) == [.launchRequested, .launchFailed])
    }
    @Test func replacedServiceCannotAuthorizeExitOrCancellation() async throws {
      await #expect(throws: CKSimError.self) {
        try await ProcessLifecycle.supervise(
          target: target(replaced: true), container: app.container, envelope: envelope(),
          environment: [:], hasExited: { _ in true })
      }
      #expect(try rows().map(\.event) == [.launchRequested])
    }
    @Test func partialTerminalEvidenceFailsWithoutFalseCancellation() async throws {
      let plan = try envelope()
      let file = app.channel.appending(path: "\(FakeApp.runID)/events.jsonl")
      try Data("{\"partial\":".utf8).write(to: file)
      await #expect(throws: CKSimError.self) {
        try await ProcessLifecycle.supervise(
          target: target(), container: app.container, envelope: plan, environment: [:],
          hasExited: { _ in true })
      }
      #expect(try rows().map(\.event) == [.launchRequested, .exited])
    }
    @Test func missingReadinessHasTimeoutReasonsWithoutZeroTimings() async throws {
      let probes = Mutex(0)
      try await ProcessLifecycle.supervise(
        target: target(), container: app.container, envelope: envelope(), environment: [:],
        observationTimeout: .zero,
        hasExited: { _ in
          probes.withLock { value in
            value += 1
            return value > 1
          }
        })
      let projection = try ProcessJournal(channel: app.channel, identity: identity()).readiness(
        pid: FakeApp.pid)
      #expect(projection.registry == nil && projection.handler == nil)
      #expect(projection.registryTimedOut && projection.handlerTimedOut)
      let json = try #require(
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(projection)) as? [String: Any])
      #expect(json["launchToRegistryMS"] == nil && json["entryToHandlerMS"] == nil)
    }
    @Test func readinessUsesOnlyThisInvocationsAnchorsAndNativeGeneration() throws {
      try app.append([
        ["event": "process.entered", "boundarySource": "runtime-preparation"],
        ["event": "runtime.ready", "boundarySource": "hooks-installed"],
        ["event": "push.registryReady", "boundarySource": "registry-delivery-queue"],
        [
          "event": "app.handlerReady", "boundarySource": "native-handler-acknowledgement",
          "generation": 2,
        ],
      ])
      let projection = try ProcessJournal(channel: app.channel, identity: identity()).readiness(
        pid: FakeApp.pid)
      let json = try #require(
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(projection)) as? [String: Any])
      #expect(json["entryToRegistryMS"] as? Double == 20)
      #expect(json["runtimeToHandlerMS"] as? Double == 20)
      #expect(json["launchToHandlerMS"] == nil)
      #expect(projection.handler?.generation == 2)
    }
    @Test func cancellationLeaseExcludesOtherHostWritersUntilReleased() async throws {
      let first = try ProcessLifecycle(channel: app.channel, identity: identity())
      let second = try ProcessLifecycle(channel: app.channel, identity: identity())
      let lease = try await first.cancellationLease()
      let acquired = Mutex(false)
      let task = Task {
        let other = try await second.cancellationLease()
        acquired.withLock { $0 = true }
        try other.close()
      }
      try await Task.sleep(for: .milliseconds(30))
      #expect(!acquired.withLock { $0 })
      try lease.close()
      try await task.value
      #expect(acquired.withLock { $0 })
    }
    @Test func cancellationWithWrongPIDFailsClosed() async throws {
      let plan = try envelope()
      let journal = try ProcessLifecycle(channel: app.channel, identity: identity())
      try await journal.record(
        .cancelled, pid: FakeApp.pid + 1, requestID: plan.id, pushID: plan.deliveryIDs[0])
      #expect(throws: CKSimError.self) {
        try ProcessJournal(channel: app.channel, identity: identity()).pendingLaunchDeliveries(
          plan, pid: FakeApp.pid)
      }
    }
    @Test func transportFailureCannotClaimCancellationOrRemoveEnvelope() async throws {
      let plan = try envelope()
      let file = app.channel.appending(path: "push-launch.json")
      let bytes = try JSONEncoder().encode(plan)
      try bytes.write(to: file)
      let uncertain = Target(
        simctl: Simctl { _, _, _ in throw ProcessTimeout() }, device: device, bundle: bundle)
      await #expect(throws: ProcessTimeout.self) {
        try await ProcessLifecycle.supervise(
          target: uncertain, container: app.container, envelope: plan, environment: [:])
      }
      #expect(try Data(contentsOf: file) == bytes)
      #expect(try rows().map(\.event) == [.launchRequested, .launchFailed])
    }
    @Test(arguments: ["wrong-request", "duplicate-schedule"])
    func contradictoryNativeScheduleCannotProduceCancellation(kind: String) async throws {
      let plan = try envelope()
      let journal = try ProcessLifecycle(channel: app.channel, identity: identity())
      for id in plan.deliveryIDs {
        try await journal.record(.launchScheduled, requestID: plan.id, pushID: id)
      }
      let event: [String: Any] = [
        "event": "push.scheduled", "pushID": plan.deliveryIDs[0].uuidString,
        "requestID": (kind == "wrong-request" ? UUID() : plan.id).uuidString,
        "uptimeNanoseconds": DispatchTime.now().uptimeNanoseconds,
      ]
      try app.append(kind == "duplicate-schedule" ? [event, event] : [event])
      #expect(throws: CKSimError.self) {
        try ProcessJournal(channel: app.channel, identity: identity()).pendingLaunchDeliveries(
          plan, pid: FakeApp.pid)
      }
    }
  }
#endif
