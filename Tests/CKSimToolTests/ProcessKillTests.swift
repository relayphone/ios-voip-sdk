#if os(macOS)
  import ArgumentParser
  import CKSimProtocol
  import Foundation
  import Synchronization
  import Testing

  @testable import CKSimTool

  final class ProcessKillTests: Sendable {
    let scratch: Scratch
    let app: FakeApp
    let state = Mutex(State())

    struct State {
      var queries = 0
      var signals: [Int32] = []
      var commands: [[String]] = []
      var stopped = false
      var replaceAtQuery: Int?
      var queryFailure = false
      var ignoreKill = false
      var replaceSession = false
      var cancelAtQuery: Int?
    }

    init() throws {
      scratch = try Scratch()
      app = try FakeApp(in: scratch.url)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: app.channel.path)
    }

    var target: Target {
      Target(
        simctl: Simctl { [self] arguments, _, _ in
          state.withLock { value in
            value.commands.append(arguments)
            if arguments.first == "get_app_container" {
              return ProcessOutput(standardOutput: Data(app.container.path.utf8))
            }
            if arguments == ["terminate", device, bundle] {
              if !value.ignoreKill { value.stopped = true }
              return ProcessOutput()
            }
            if arguments == ["spawn", device, "launchctl", "list"] {
              value.queries += 1
              if value.cancelAtQuery == value.queries {
                withUnsafeCurrentTask { $0?.cancel() }
              }
              if value.replaceSession, value.queries == 1 {
                let replacement = try! RuntimeSession(
                  bundleID: bundle, runID: "replacement", pid: FakeApp.pid, profile: "ios-27.0")
                try! JSONEncoder().encode(replacement).write(
                  to: app.channel.appending(path: "session.json"))
              }
              if value.queryFailure { return ProcessOutput(status: 1) }
              let pid = value.replaceAtQuery == value.queries ? FakeApp.pid + 1 : FakeApp.pid
              let table =
                value.stopped
                ? "PID Status Label\n- 0 UIKitApplication:\(bundle)[test]\n"
                : "PID Status Label\n\(pid) 0 UIKitApplication:\(bundle)[test]\n"
              return ProcessOutput(standardOutput: Data(table.utf8))
            }
            return ProcessOutput(status: 1)
          }
        }, device: device, bundle: bundle)
    }

    func kill(_ cause: ProcessExitCause = .abrupt, runID: String = FakeApp.runID) async throws
      -> ProcessLifecycle.KillReceipt
    {
      try await ProcessLifecycle.kill(
        target: target, runID: runID, cause: cause, timeout: .zero,
        signal: { [self] pid in
          state.withLock {
            $0.signals.append(pid)
            if !$0.ignoreKill { $0.stopped = true }
          }
        }, hasExited: { [self] _ in state.withLock { $0.stopped } })
    }

    func observations() throws -> [ProcessLifecycleRecord] {
      let directory = app.channel.appending(path: "process/\(FakeApp.runID)")
      guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
      return try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
      )
      .flatMap { file in
        try Data(contentsOf: file).split(separator: 10).map {
          try JSONDecoder().decode(ProcessLifecycleRecord.self, from: Data($0))
        }
      }
    }

    @Test(arguments: [ProcessExitCause.abrupt, .userRequested])
    func verifiedKillRecordsIntentAndConfirmedExit(cause: ProcessExitCause) async throws {
      let receipt = try await kill(cause)
      #expect(receipt.exited && receipt.pid == FakeApp.pid && receipt.cause == cause)
      let rows = try observations()
      #expect(rows.map(\.event) == [.killRequested, .exited])
      #expect(rows.map(\.sequence) == [1, 2])
      #expect(rows.allSatisfy { $0.pid == FakeApp.pid && $0.cause == cause })
      #expect(rows[1].uptimeNanoseconds >= rows[0].uptimeNanoseconds)
      state.withLock {
        #expect($0.signals == (cause == .abrupt ? [Int32(FakeApp.pid)] : []))
        #expect($0.commands.contains(["terminate", device, bundle]) == (cause == .userRequested))
      }
    }

    @Test func intentIsFlushedBeforeSignal() async throws {
      _ = try await ProcessLifecycle.kill(
        target: target, runID: FakeApp.runID, cause: .abrupt, timeout: .zero,
        signal: { [self] _ in
          let rows = try observations()
          #expect(rows.map(\.event) == [.killRequested])
          state.withLock { $0.stopped = true }
        }, hasExited: { [self] _ in state.withLock { $0.stopped } })
    }

    @Test func wrongRunNeverSignalsOrRecordsIntent() async throws {
      await #expect(throws: CKSimError.self) { try await kill(runID: "old-run") }
      #expect(state.withLock { $0.signals.isEmpty && $0.queries == 0 })
      #expect(try observations().isEmpty)
    }

    @Test(arguments: [1, 2, 3])
    func changedPIDNeverClaimsExit(query: Int) async throws {
      state.withLock {
        $0.replaceAtQuery = query
        if query == 3 { $0.ignoreKill = true }
      }
      await #expect(throws: CKSimError.self) { try await kill() }
      // For the post-kill case, keep the old service visible until the replacement is observed.
      if query < 3 { #expect(state.withLock { $0.signals.isEmpty }) }
      #expect(try observations().allSatisfy { $0.event != .exited })
    }

    @Test func failedQueryNeverSignals() async throws {
      state.withLock { $0.queryFailure = true }
      await #expect(throws: CKSimError.self) { try await kill() }
      #expect(state.withLock { $0.signals.isEmpty })
    }

    @Test func unconfirmedExitIsNotSuccess() async throws {
      state.withLock { $0.ignoreKill = true }
      await #expect(throws: CKSimError.self) { try await kill() }
      #expect(try observations().map(\.event) == [.killRequested])
    }

    @Test func replacedSessionWithSamePIDNeverSignals() async throws {
      state.withLock { $0.replaceSession = true }
      await #expect(throws: CKSimError.self) { try await kill() }
      #expect(state.withLock { $0.signals.isEmpty })
      #expect(try observations().map(\.event) == [.killRequested])
    }

    @Test func failedSignalDoesNotClaimExit() async throws {
      await #expect(throws: CKSimError.self) {
        try await ProcessLifecycle.kill(
          target: target, runID: FakeApp.runID, cause: .abrupt, timeout: .zero,
          signal: { _ in throw CKSimError("signal denied") })
      }
      #expect(try observations().map(\.event) == [.killRequested])
    }

    @Test func cancellationDuringFinalVerificationNeverSignals() async throws {
      state.withLock { $0.cancelAtQuery = 2 }
      let worker = Task { try await self.kill() }
      await #expect(throws: CancellationError.self) { try await worker.value }
      #expect(state.withLock { $0.signals.isEmpty })
      #expect(try observations().map(\.event) == [.killRequested])
    }

    @Test(arguments: [false, true])
    func absentServiceNeedsConfirmedPIDExit(probeThrows: Bool) async throws {
      await #expect(throws: CKSimError.self) {
        try await ProcessLifecycle.kill(
          target: target, runID: FakeApp.runID, cause: .abrupt, timeout: .zero,
          signal: { [self] _ in state.withLock { $0.stopped = true } },
          hasExited: { _ in
            if probeThrows { throw CKSimError("liveness unknown") }
            return false
          })
      }
      #expect(try observations().map(\.event) == [.killRequested])
    }

    @Test(arguments: [
      "", "garbage", "PID Status Label\n12 nope UIKitApplication:x[y]",
      "PID Status Label\n123 0 UIKitApplication:dev.example.app[a]\n124 0 UIKitApplication:dev.example.app[b]",
      "PID Status Label\n123 0 UIKitApplication:dev.example.app[]",
    ])
    func unsafeServiceTablesAreRefused(table: String) {
      #expect(throws: CKSimError.self) {
        try ProcessLifecycle.AppService.read(Data(table.utf8), bundle: bundle)
      }
    }

    @Test func otherBundleAndStoppedServicesDoNotAuthorizeKill() throws {
      let table =
        "PID Status Label\n123 0 UIKitApplication:\(bundle).other[a]\n- 0 UIKitApplication:\(bundle)[b]"
      #expect(try ProcessLifecycle.AppService.read(Data(table.utf8), bundle: bundle) == nil)
    }

    @Test func nestedCLIRequiresExplicitCauseAndRun() throws {
      let args = CKSim.arguments([
        "--simulator", device, "--bundle", bundle, "process", "kill", "--run-id", FakeApp.runID,
        "--cause", "abrupt",
      ])
      let command = try #require(CKSim.parseAsRoot(args) as? CKSim.ProcessControl.Kill)
      #expect(command.options.bundle == bundle && command.runID == FakeApp.runID)
      for flags in [["--cause", "unknown"], ["--cause", "abrupt"], ["--run-id", "x"]] {
        #expect(throws: (any Error).self) {
          try CKSim.parseAsRoot(["process", "kill", "--bundle", bundle] + flags)
        }
      }
    }
  }
#endif
