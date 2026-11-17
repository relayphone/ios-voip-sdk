#if os(macOS)
  import ArgumentParser
  import CKSimProtocol
  import Darwin
  import Foundation
  import Synchronization
  import Testing

  @testable import CKSimTool

  @Suite(.timeLimit(.minutes(1)))
  struct ProcessSuspensionTests {
    private final class Fixture: Sendable {
      let scratch: Scratch
      let app: FakeApp
      let state = Mutex(State())
      struct State {
        var pid = FakeApp.pid
        var birth: UInt64 = 10
        var status = ProcessSuspension.Snapshot.State.running
        var signals: [ProcessSuspension.Signal] = []
        var commands: [[String]] = []
        var ignoreStop = false
        var ignoreResume = false
        var failStop = false
        var failResume = false
        var cancelOnStop = false
        var interruptOnStop = false
        var replaceOnStop = false
        var changeSessionOnStop = false
        var interrupt = false
        var invalidService = false
      }
      init() throws {
        scratch = try Scratch()
        app = try FakeApp(in: scratch.url)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: app.channel.path)
      }
      var target: Target {
        Target(
          simctl: Simctl { [self] args, _, _ in
            state.withLock {
              $0.commands.append(args)
              if $0.signals.last == .stop {
                Issue.record(
                  "Simulator queries must not delay recovery of an owned stopped process")
              }
              if args.first == "get_app_container" {
                return ProcessOutput(standardOutput: Data(app.container.path.utf8))
              }
              if args == ["spawn", device, "launchctl", "list"] {
                let pid = $0.invalidService ? $0.pid + 1 : $0.pid
                return ProcessOutput(
                  standardOutput: Data(
                    "PID Status Label\n\(pid) 0 UIKitApplication:\(bundle)[fixture]\n".utf8))
              }
              return ProcessOutput(status: 1)
            }
          }, device: device, bundle: bundle)
      }
      var system: ProcessSuspension.System {
        .init(
          snapshot: { [self] _ in
            state.withLock {
              .init(startSeconds: $0.birth, startMicroseconds: 1, state: $0.status)
            }
          },
          signal: { [self] _, signal in
            let changeSession = try state.withLock { state in
              state.signals.append(signal)
              switch signal {
              case .stop:
                if !state.ignoreStop { state.status = .stopped }
                if state.replaceOnStop { state.birth += 1 }
                if state.cancelOnStop { withUnsafeCurrentTask { $0?.cancel() } }
                if state.interruptOnStop { state.interrupt = true }
                if state.failStop { throw CKSimError("uncertain stop outcome") }
              case .resume:
                if state.failResume { throw CKSimError("resume failed") }
                if !state.ignoreResume { state.status = .running }
              }
              return signal == .stop && state.changeSessionOnStop
            }
            if changeSession {
              try JSONEncoder().encode(
                RuntimeSession(
                  bundleID: bundle, runID: "replacement", pid: FakeApp.pid, profile: "ios-27.0")
              ).write(to: app.channel.appending(path: "session.json"))
            }
          })
      }
      func run(record: ProcessSuspension.Record? = nil) async throws -> ProcessSuspension.Receipt {
        try await ProcessSuspension.run(
          target: target, runID: FakeApp.runID, duration: .milliseconds(1), timeout: .zero,
          system: system, interrupted: { [self] in state.withLock { $0.interrupt } }, record: record
        )
      }
      func rows() throws -> [ProcessLifecycleRecord] {
        let identity = try ProcessLifecycleIdentity(
          simulatorID: UUID(uuidString: device)!, bundleID: bundle, runID: FakeApp.runID)
        return try ProcessJournal(channel: app.channel, identity: identity).read().map {
          try JSONDecoder().decode(ProcessLifecycleRecord.self, from: $0.line)
        }
      }
    }

    @Test func confirmedStopAndResumeUseOnlyHostEvidence() async throws {
      let f = try Fixture()
      let receipt = try await f.run()
      #expect(receipt.outcome == .resumed && receipt.pid == FakeApp.pid)
      let rows = try f.rows()
      #expect(rows.map(\.event) == [.suspendRequested, .suspended, .resumed])
      #expect(rows.allSatisfy { $0.requestID == receipt.requestID && $0.pid == FakeApp.pid })
      #expect(rows.map(\.sequence) == [1, 2, 3])
      f.state.withLock {
        #expect($0.signals == [.stop, .resume] && $0.status == .running)
        #expect($0.commands.allSatisfy { $0.first == "get_app_container" || $0.first == "spawn" })
      }
    }

    @Test(arguments: [false, true])
    func cancelledOrInterruptedOwnerStillResumes(hostInterrupt: Bool) async throws {
      let f = try Fixture()
      f.state.withLock {
        $0.interruptOnStop = hostInterrupt
        $0.cancelOnStop = !hostInterrupt
      }
      let worker = Task { try await f.run() }
      await #expect(throws: CancellationError.self) { try await worker.value }
      f.state.withLock { #expect($0.signals == [.stop, .resume] && $0.status == .running) }
      #expect(try f.rows().last?.event == .resumed)
    }

    @Test func uncertainStopAndUnconfirmedStopCannotStrandTheOriginal() async throws {
      for ignored in [false, true] {
        let f = try Fixture()
        f.state.withLock {
          $0.failStop = !ignored
          $0.ignoreStop = ignored
        }
        await #expect(throws: CKSimError.self) { try await f.run() }
        f.state.withLock { #expect($0.signals == [.stop, .resume] && $0.status == .running) }
      }
    }

    @Test func changedSessionDoesNotPreventRecoveryOfPinnedProcess() async throws {
      let f = try Fixture()
      f.state.withLock { $0.changeSessionOnStop = true }
      await #expect(throws: CKSimError.self) { try await f.run() }
      f.state.withLock { #expect($0.signals == [.stop, .resume] && $0.status == .running) }
    }

    @Test func reusedPIDCannotReceiveContinue() async throws {
      let f = try Fixture()
      f.state.withLock { $0.replaceOnStop = true }
      await #expect(throws: CKSimError.self) { try await f.run() }
      #expect(f.state.withLock { $0.signals } == [.stop])
      #expect(try f.rows().last?.event == .exited)
    }

    @Test(arguments: [false, true])
    func failedOrUnconfirmedResumeIsNeverSuccessful(ignore: Bool) async throws {
      let f = try Fixture()
      f.state.withLock {
        $0.failResume = !ignore
        $0.ignoreResume = ignore
      }
      await #expect(throws: ProcessSuspension.RecoveryFailure.self) { try await f.run() }
      let events = try f.rows().map(\.event)
      #expect(!events.contains(.resumed) && events.last == .suspensionCleanupFailed)
    }

    @Test(arguments: [ProcessLifecycleEvent.suspended, .resumed])
    func journalFailureAfterStopStillContinuesBeforeReportingFailure(
      failedEvent: ProcessLifecycleEvent
    ) async throws {
      let f = try Fixture()
      let identity = try ProcessLifecycleIdentity(
        simulatorID: UUID(uuidString: device)!, bundleID: bundle, runID: FakeApp.runID)
      let journal = try ProcessLifecycle(channel: f.app.channel, identity: identity)
      await #expect(throws: (any Error).self) {
        try await f.run { event, request in
          if event == failedEvent { throw CKSimError("journal write failed") }
          try await journal.record(event, pid: FakeApp.pid, requestID: request)
        }
      }
      f.state.withLock { #expect($0.signals == [.stop, .resume] && $0.status == .running) }
    }

    @Test func preexistingStopOrWrongServiceCannotAuthorizeAnySignal() async throws {
      for wrongService in [false, true] {
        let f = try Fixture()
        f.state.withLock {
          $0.invalidService = wrongService
          $0.status = wrongService ? .running : .stopped
        }
        await #expect(throws: CKSimError.self) { try await f.run() }
        #expect(f.state.withLock { $0.signals.isEmpty })
      }
    }

    @Test func anotherSignalOwnerPreventsStopAndKill() async throws {
      let f = try Fixture()
      let identity = try ProcessLifecycleIdentity(
        simulatorID: UUID(uuidString: device)!, bundleID: bundle, runID: FakeApp.runID)
      let owner = try ProcessLifecycle(channel: f.app.channel, identity: identity)
      let lease = try owner.signalLease()
      defer { try? lease.close() }
      let otherRun = try ProcessLifecycle(
        channel: f.app.channel,
        identity: ProcessLifecycleIdentity(
          simulatorID: UUID(uuidString: device)!, bundleID: bundle, runID: "new-run"))
      #expect(throws: CKSimError.self) { try otherRun.signalLease() }
      await #expect(throws: CKSimError.self) { try await f.run() }
      await #expect(throws: CKSimError.self) {
        try await ProcessLifecycle.kill(
          target: f.target, runID: FakeApp.runID, cause: .abrupt, timeout: .zero,
          signal: { _ in Issue.record("A competing owner must not terminate the process") })
      }
      #expect(f.state.withLock { $0.signals.isEmpty })
    }

    @Test func commandRequiresBoundedExplicitWakeAndInvocation() throws {
      let args = CKSim.arguments([
        "--simulator", device, "--bundle", bundle, "process", "suspend", "--run-id", FakeApp.runID,
        "--resume-after-ms", "300",
      ])
      let command = try #require(CKSim.parseAsRoot(args) as? CKSim.ProcessControl.Suspend)
      #expect(command.resumeAfterMS == 300 && command.runID == FakeApp.runID)
      for flags in [
        ["--run-id", "x"], ["--resume-after-ms", "1"], ["--run-id", "x", "--resume-after-ms", "0"],
        ["--run-id", "x", "--resume-after-ms", "120001"],
      ] {
        #expect(throws: (any Error).self) {
          try CKSim.parseAsRoot(["process", "suspend", "--bundle", bundle] + flags)
        }
      }
    }

    @Test func realProcessHeartbeatStopsAndRestartsWithoutAnAppMailbox() async throws {
      let f = try Fixture()
      let heartbeat = f.scratch.url.appending(path: "heartbeat")
      let script = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "tools/fixtures/process-heartbeat.ts")
      let child = Process()
      child.executableURL = URL(filePath: "/usr/bin/env")
      child.arguments = ["node", script.path, heartbeat.path]
      child.standardOutput = FileHandle.nullDevice
      child.standardError = FileHandle.nullDevice
      try child.run()
      let pid = child.processIdentifier
      let original = try? ProcessSuspension.System.live.snapshot(pid)
      defer {
        // Always continue our still-pinned child before termination, including assertion failure.
        if let original, let current = try? ProcessSuspension.System.live.snapshot(pid),
          current.sameProcess(as: original)
        {
          _ = Darwin.kill(pid, SIGCONT)
        }
        if child.isRunning { child.terminate() }
        child.waitUntilExit()
      }
      _ = try #require(original)
      func count() throws -> Int { Int(try String(contentsOf: heartbeat, encoding: .utf8)) ?? 0 }
      let ready = ContinuousClock.now + .seconds(10)
      while !FileManager.default.fileExists(atPath: heartbeat.path) {
        guard child.isRunning, ContinuousClock.now < ready else {
          throw CKSimError("Heartbeat fixture did not start.")
        }
        try await Task.sleep(for: .milliseconds(25))
      }
      let initial = try count()
      try await Task.sleep(for: .milliseconds(100))
      #expect(try count() > initial, "Unprotected control must make progress")
      f.state.withLock { $0.pid = Int(pid) }
      try JSONEncoder().encode(
        RuntimeSession(bundleID: bundle, runID: FakeApp.runID, pid: Int(pid), profile: "ios-27.0")
      )
      .write(to: f.app.channel.appending(path: "session.json"))
      let worker = Task {
        try await ProcessSuspension.run(
          target: f.target, runID: FakeApp.runID, duration: .seconds(2), timeout: .seconds(5))
      }
      do {
        let deadline = ContinuousClock.now + .seconds(10)
        while try !f.rows().contains(where: { $0.event == .suspended }) {
          guard ContinuousClock.now < deadline else { throw CKSimError("No confirmed suspension.") }
          try await Task.sleep(for: .milliseconds(25))
        }
        #expect(try ProcessSuspension.System.live.snapshot(pid)?.state == .stopped)
        let stopped = try count()
        try await Task.sleep(for: .milliseconds(100))
        #expect(try count() == stopped, "Whole-process heartbeat must stop")
        #expect(try await worker.value.outcome == .resumed)
        let progressed = ContinuousClock.now + .seconds(5)
        while try count() == stopped {
          guard ContinuousClock.now < progressed else {
            throw CKSimError("Heartbeat did not resume.")
          }
          try await Task.sleep(for: .milliseconds(25))
        }
        #expect(try f.rows().map(\.event) == [.suspendRequested, .suspended, .resumed])
      } catch {
        worker.cancel()
        _ = await worker.result
        throw error
      }
    }
  }
#endif
