#if os(macOS)
  import CKSimProtocol
  import Darwin
  import Foundation

  /// A bounded host-owned stop/wake interval. Never waits for the stopped app's mailbox.
  enum ProcessSuspension {
    enum Signal: Equatable, Sendable { case stop, resume }
    struct Snapshot: Equatable, Sendable {
      enum State: Sendable { case running, stopped }
      let startSeconds: UInt64
      let startMicroseconds: UInt64
      let state: State
      func sameProcess(as other: Self) -> Bool {
        startSeconds == other.startSeconds && startMicroseconds == other.startMicroseconds
      }
    }
    struct System: Sendable {
      var snapshot: @Sendable (Int32) throws -> Snapshot?
      var signal: @Sendable (Int32, Signal) throws -> Void

      static let live = Self(
        snapshot: { pid in
          var info = proc_bsdinfo()
          errno = 0
          let count = proc_pidinfo(
            pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
          if count == 0, errno == ESRCH || errno == ENOENT { return nil }
          guard count == MemoryLayout.size(ofValue: info), info.pbi_start_tvsec > 0 else {
            throw CKSimError("Cannot inspect process start time and kernel state.")
          }
          if info.pbi_status == SZOMB { return nil }
          guard [SIDL, SRUN, SSLEEP, SSTOP].contains(Int32(info.pbi_status)) else {
            throw CKSimError("Unknown kernel process state.")
          }
          return Snapshot(
            startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec,
            state: info.pbi_status == SSTOP ? .stopped : .running)
        },
        signal: { pid, signal in
          guard Darwin.kill(pid, signal == .stop ? SIGSTOP : SIGCONT) == 0 else {
            throw CKSimError("Cannot signal verified process: \(String(cString: strerror(errno)))")
          }
        })
    }
    enum Outcome: String, Encodable, Sendable { case resumed, exited }
    struct Receipt: Encodable, Sendable {
      let schemaVersion = 1
      let identity: ProcessLifecycleIdentity
      let pid: Int
      let requestID: UUID
      let outcome: Outcome
    }
    struct RecoveryFailure: Error, CustomStringConvertible {
      let pid: Int32
      let start: Snapshot
      let operation: (any Error)?
      let recovery: any Error
      var description: String {
        "Suspension cleanup failed for PID \(pid), start \(start.startSeconds).\(start.startMicroseconds); "
          + "inspect the pinned process before termination. "
          + "Operation: \(operation.map(String.init(describing:)) ?? "completed"); recovery: \(recovery)"
      }
    }
    typealias Record = @Sendable (ProcessLifecycleEvent, UUID) async throws -> Void

    static func run<C: Clock>(
      target: Target, runID: String, duration: Duration, timeout: Duration,
      clock: C = ContinuousClock(), system: System = .live,
      interrupted: @escaping @Sendable () -> Bool = { false }, record override: Record? = nil
    ) async throws -> Receipt where C.Duration == Duration {
      guard duration > .zero, duration <= .seconds(120), timeout >= .zero,
        timeout <= .seconds(120), let simulator = UUID(uuidString: target.device)
      else { throw CKSimError("Require a resolved simulator and suspension in (0,120] seconds.") }
      let identity = try ProcessLifecycleIdentity(
        simulatorID: simulator, bundleID: target.bundle, runID: runID)
      // A cached container is never authority to signal a process.
      let container = URL(
        filePath: try target.simctl("get_app_container", target.device, target.bundle, "data"))
      let channel = container.appending(path: "Documents/.callkit-simulator")
      let session = try PublishedSession(channel: channel, bundle: target.bundle).session
      guard session.runID == runID, let pid = Int32(exactly: session.pid), pid > 1, pid != getpid()
      else { throw CKSimError("Requested run does not match a signalable app process.") }
      func service() throws -> ProcessLifecycle.AppService? {
        let output = try target.simctl.run(
          ["spawn", target.device, "launchctl", "list"],
          ProcessInfo.processInfo.environment.merging(["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": ""]) {
            $1
          },
          Simctl.limit)
        guard output.status == 0, output.standardError.isEmpty else {
          throw CKSimError("Cannot verify simulator app service.")
        }
        return try ProcessLifecycle.AppService.read(output.standardOutput, bundle: target.bundle)
      }
      guard let originalService = try service(), originalService.pid == session.pid,
        let original = try system.snapshot(pid), original.state == .running
      else { throw CKSimError("Require a matching live app service that is not already stopped.") }
      func verify() throws {
        let current = URL(
          filePath: try target.simctl("get_app_container", target.device, target.bundle, "data"))
        guard current.standardizedFileURL == container.standardizedFileURL,
          try PublishedSession(channel: channel, bundle: target.bundle).session == session,
          try service() == originalService,
          let now = try system.snapshot(pid), now.sameProcess(as: original)
        else {
          throw CKSimError(
            "App invocation or process start time changed; control outcome is unverified.")
        }
      }
      func checkCancellation() throws {
        try Task.checkCancellation()
        if interrupted() { throw CancellationError() }
      }
      let journal = try ProcessLifecycle(channel: channel, identity: identity)
      let lease = try journal.signalLease()
      defer { try? lease.close() }
      let record: Record =
        override ?? { event, request in
          try await journal.record(event, pid: session.pid, requestID: request)
        }
      let request = UUID()
      try checkCancellation()
      try await record(.suspendRequested, request)
      try verify()
      guard let beforeStop = try system.snapshot(pid), beforeStop.sameProcess(as: original),
        beforeStop.state == .running
      else {
        throw CKSimError("Process stopped before this command took ownership.")
      }
      try checkCancellation()
      var failure: (any Error)?
      do {
        // Once stop is attempted, every path must attempt recovery, even a signal error.
        try system.signal(pid, .stop)
        let deadline = clock.now.advanced(by: timeout)
        while true {
          try checkCancellation()
          guard let now = try system.snapshot(pid), now.sameProcess(as: original) else {
            throw CKSimError("Original process exited before suspension was confirmed.")
          }
          if now.state == .stopped { break }
          guard clock.now < deadline else {
            throw CKSimError("Kernel stop confirmation timed out.")
          }
          try await clock.sleep(for: .milliseconds(25))
        }
        let wake = clock.now.advanced(by: duration)
        try await record(.suspended, request)
        while clock.now < wake {
          try checkCancellation()
          try await clock.sleep(
            until: min(wake, clock.now.advanced(by: .milliseconds(25))), tolerance: nil)
        }
        try checkCancellation()
      } catch { failure = error }

      // Recovery cannot inherit caller cancellation and never consults the app's mailbox or
      // a replacement session. Kernel start time pins the original process for SIGCONT.
      let recovery = Task.detached {
        guard let now = try system.snapshot(pid), now.sameProcess(as: original) else {
          try await record(.exited, request)
          return Outcome.exited
        }
        try system.signal(pid, .resume)
        let deadline = clock.now.advanced(by: timeout)
        while true {
          guard let now = try system.snapshot(pid), now.sameProcess(as: original) else {
            try await record(.exited, request)
            return Outcome.exited
          }
          if now.state == .running {
            try await record(.resumed, request)
            return Outcome.resumed
          }
          guard clock.now < deadline else {
            throw CKSimError("Kernel resume confirmation timed out.")
          }
          try await clock.sleep(for: .milliseconds(25))
        }
      }
      let outcome: Outcome
      do { outcome = try await recovery.value } catch {
        try? await record(.suspensionCleanupFailed, request)
        throw RecoveryFailure(pid: pid, start: original, operation: failure, recovery: error)
      }
      if let failure { throw failure }
      if outcome == .resumed { try verify() }
      try checkCancellation()
      return Receipt(identity: identity, pid: session.pid, requestID: request, outcome: outcome)
    }
  }
#endif
