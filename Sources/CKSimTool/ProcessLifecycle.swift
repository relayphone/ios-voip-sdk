#if os(macOS)
  import CKSimProtocol
  import Darwin
  import Foundation

  /// One host writer per exclusive segment. Never opens the runtime's events.jsonl for writing.
  actor ProcessLifecycle {
    nonisolated let identity: ProcessLifecycleIdentity
    nonisolated let producerID: UUID
    nonisolated let file: URL
    private let handle: FileHandle
    private var sequence: UInt64 = 0
    private var lastUptime: UInt64 = 0
    private var failed = false

    init(channel: URL, identity: ProcessLifecycleIdentity, producerID: UUID = UUID()) throws {
      self.identity = identity
      self.producerID = producerID
      let directory = channel.appending(path: "process/\(identity.runID)")
      for folder in [channel, channel.appending(path: "process"), directory] {
        try FileManager.default.createDirectory(
          at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var status = stat()
        guard lstat(folder.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
          status.st_uid == getuid(), status.st_mode & 0o7777 == 0o700
        else { throw CKSimError("Unsafe process journal directory.") }
      }
      file = directory.appending(path: "\(producerID.uuidString).jsonl")
      let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard descriptor >= 0 else { throw CKSimError("Cannot create exclusive process segment.") }
      handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// Persists an observation before returning, so an ensuing exec or kill cannot lose intent.
    func record(
      _ event: ProcessLifecycleEvent, pid: Int? = nil, requestID: UUID? = nil,
      pushID: UUID? = nil, cause: ProcessExitCause? = nil,
      uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
      wallTimeMS: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) throws {
      guard !failed else { throw CKSimError("Process segment failed; start a new producer.") }
      guard uptimeNanoseconds >= lastUptime else {
        throw CKSimError("Process segment monotonic time moved backwards.")
      }
      let row = try ProcessLifecycleRecord(
        identity: identity, producerID: producerID, sequence: sequence + 1, pid: pid,
        event: event, uptimeNanoseconds: uptimeNanoseconds, wallTimeMS: wallTimeMS,
        requestID: requestID, pushID: pushID, cause: cause)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      var bytes = try encoder.encode(row)
      bytes.append(10)
      do {
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
      } catch {
        failed = true
        throw error
      }
      sequence = row.sequence
      lastUptime = uptimeNanoseconds
    }
  }

  extension ProcessLifecycle {
    struct KillReceipt: Encodable, Sendable {
      let schemaVersion = 1
      let identity: ProcessLifecycleIdentity
      let pid: Int
      let cause: ProcessExitCause
      let exited: Bool
      let cancelledDeliveries: [UUID]
    }

    /// Stops only a live service matching the pinned runtime session. No runtime mailbox is needed.
    static func kill(
      target: Target, runID: String, cause: ProcessExitCause, timeout: Duration,
      clock: some Clock<Duration> = ContinuousClock(),
      signal: @Sendable (Int32) throws -> Void = { pid in
        guard Darwin.kill(pid, SIGKILL) == 0 else {
          throw CKSimError("Cannot kill verified process: \(String(cString: strerror(errno)))")
        }
      },
      hasExited: @Sendable (Int32) throws -> Bool = { pid in
        if Darwin.kill(pid, 0) == 0 { return false }
        guard errno == ESRCH else { throw CKSimError("Cannot establish old process exit.") }
        return true
      }
    ) async throws -> KillReceipt {
      guard cause != .unknown, let simulator = UUID(uuidString: target.device) else {
        throw CKSimError("Require a resolved simulator and an explicit kill cause.")
      }
      let identity = try ProcessLifecycleIdentity(
        simulatorID: simulator, bundleID: target.bundle, runID: runID)
      // Always resolve the installed bundle again; a cached container cannot authorize a signal.
      let container = URL(
        filePath: try target.simctl("get_app_container", target.device, target.bundle, "data"))
      let channel = container.appending(path: "Documents/.callkit-simulator")
      let session = try PublishedSession(channel: channel, bundle: target.bundle).session
      guard session.runID == runID, Int32(exactly: session.pid) != nil else {
        throw CKSimError("Requested run does not match a signalable runtime session.")
      }
      func verifySession() throws {
        let current = URL(
          filePath: try target.simctl("get_app_container", target.device, target.bundle, "data"))
        guard current.standardizedFileURL == container.standardizedFileURL,
          try PublishedSession(channel: channel, bundle: target.bundle).session == session
        else { throw CKSimError("Process identity changed; refusing termination or exit claim.") }
      }
      func service() throws -> AppService? {
        let output = try target.simctl.run(
          ["spawn", target.device, "launchctl", "list"],
          ProcessInfo.processInfo.environment.merging(["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": ""]) {
            $1
          }, Simctl.limit)
        guard output.status == 0, output.standardError.isEmpty else {
          throw CKSimError("Cannot verify app service: \(output.diagnostic)")
        }
        return try AppService.read(output.standardOutput, bundle: target.bundle)
      }
      guard let original = try service(), original.pid == session.pid else {
        throw CKSimError("Live app service does not match the requested runtime process.")
      }
      let journal = try ProcessLifecycle(channel: channel, identity: identity)
      try await journal.record(.killRequested, pid: session.pid, cause: cause)
      try Task.checkCancellation()
      try verifySession()
      guard try service() == original else {
        throw CKSimError("Live app service changed; refusing termination.")
      }
      try Task.checkCancellation()
      switch cause {
      case .abrupt: try signal(Int32(session.pid))
      case .userRequested:
        try target.simctl("terminate", target.device, target.bundle)
      case .unknown: preconditionFailure("Validated above")
      }
      let deadline = clock.now.advanced(by: timeout)
      repeat {
        try Task.checkCancellation()
        try verifySession()
        let current = try service()
        if current == nil, try hasExited(Int32(session.pid)) {
          try await journal.record(.exited, pid: session.pid, cause: cause)
          try Task.checkCancellation()
          let lease = try await journal.cancellationLease()
          defer { try? lease.close() }
          let pending = try ProcessJournal(channel: channel, identity: identity)
            .pendingDeliveries(pid: session.pid)
          try verifySession()
          try Task.checkCancellation()
          for delivery in pending {
            try Task.checkCancellation()
            try await journal.record(
              .cancelled, pid: session.pid, requestID: delivery.requestID,
              pushID: delivery.pushID, cause: cause)
          }
          try Task.checkCancellation()
          return KillReceipt(
            identity: identity, pid: session.pid, cause: cause, exited: true,
            cancelledDeliveries: pending.map(\.pushID))
        }
        guard current == nil || current == original else {
          throw CKSimError("App service was replaced; old process exit is unverified.")
        }
        guard clock.now < deadline else {
          throw CKSimError("Process exit timed out; outcome is unknown. Inspect before launching.")
        }
        try await clock.sleep(for: .milliseconds(50))
      } while true
    }

    /// Strict launchctl list parsing; ambiguous or malformed results cannot authorize a signal.
    struct AppService: Equatable {
      let pid: Int
      let label: String

      static func read(_ data: Data, bundle: String) throws -> Self? {
        let rows = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map {
          $0.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        guard rows.first == ["PID", "Status", "Label"], rows.count > 1 else {
          throw CKSimError("Invalid launchctl service table.")
        }
        var app: Self?
        for row in rows.dropFirst() {
          guard row.count == 3,
            row[0] == "-" || Int(row[0]).map({ $0 > 0 && String($0) == row[0] }) == true,
            row[1] == "-" || Int(row[1]) != nil
          else { throw CKSimError("Invalid launchctl service row.") }
          guard row[2].hasPrefix("UIKitApplication:\(bundle)[") else { continue }
          guard row[2].hasSuffix("]"), row[2].count > "UIKitApplication:\(bundle)[]".count else {
            throw CKSimError("Invalid app service label.")
          }
          guard let pid = Int(row[0]) else { continue }
          guard app == nil else { throw CKSimError("Multiple live app services; refusing kill.") }
          app = Self(pid: pid, label: row[2])
        }
        return app
      }
    }
  }

  /// A bounded offline snapshot: host segments are available even without a runtime session.
  struct ProcessJournal {
    struct PendingDelivery: Equatable {
      let requestID: UUID
      let pushID: UUID
    }

    private struct DeliveryObservation: Decodable {
      let pushID: UUID
      let requestID: UUID?
    }

    private enum DeliveryEvent: String {
      case scheduled = "push.scheduled"
      case received = "push.received"
      case dropped = "push.dropped"
    }

    /// Reconstructs undelivered copies only from a validated snapshot of the pinned invocation.
    /// A delegate entry ends pending status even when reporting or completion is still outstanding.
    func pendingDeliveries(pid: Int) throws -> [PendingDelivery] {
      var scheduled: [PendingDelivery] = []
      var requests: [UUID: UUID] = [:]
      var runtimeSchedules = Set<UUID>()
      var terminal = Set<UUID>()
      var correlatedTerminals: [PendingDelivery] = []
      for entry in try read(requireCompleteTail: true) {
        if entry.producer.hasPrefix("runtime-") {
          guard entry.producer == "runtime-\(pid)" else {
            throw CKSimError("Delivery journal does not match the exited process.")
          }
          let header = try JSONDecoder().decode(RuntimeHeader.self, from: entry.line)
          guard let event = DeliveryEvent(rawValue: header.event) else { continue }
          let observation = try JSONDecoder().decode(DeliveryObservation.self, from: entry.line)
          if event == .scheduled {
            guard let requestID = observation.requestID,
              runtimeSchedules.insert(observation.pushID).inserted,
              requests[observation.pushID] == nil || requests[observation.pushID] == requestID
            else { throw CKSimError("Ambiguous push delivery schedule.") }
            if requests[observation.pushID] == nil {
              scheduled.append(PendingDelivery(requestID: requestID, pushID: observation.pushID))
            }
            requests[observation.pushID] = requestID
          } else {
            guard event != .dropped || observation.requestID != nil else {
              throw CKSimError("Dropped delivery lacks request correlation.")
            }
            if let requestID = observation.requestID {
              correlatedTerminals.append(
                PendingDelivery(requestID: requestID, pushID: observation.pushID))
            }
            terminal.insert(observation.pushID)
          }
        } else {
          let row = try JSONDecoder().decode(ProcessLifecycleRecord.self, from: entry.line)
          if row.event == .launchScheduled {
            guard row.pid == nil, let pushID = row.pushID, let requestID = row.requestID,
              requests[pushID] == nil
            else { throw CKSimError("Invalid retained launch schedule.") }
            requests[pushID] = requestID
            scheduled.append(PendingDelivery(requestID: requestID, pushID: pushID))
          }
          if row.event == .cancelled {
            guard row.pid == pid, let pushID = row.pushID, let requestID = row.requestID else {
              throw CKSimError("Invalid prior delivery cancellation.")
            }
            correlatedTerminals.append(PendingDelivery(requestID: requestID, pushID: pushID))
            terminal.insert(pushID)
          }
        }
      }
      for observation in correlatedTerminals {
        guard requests[observation.pushID] == observation.requestID else {
          throw CKSimError("Terminal observation does not match a scheduled delivery.")
        }
      }
      return scheduled.filter { !terminal.contains($0.pushID) }
    }

    struct Entry {
      let line: Data
      let uptimeNanoseconds: UInt64
      let producer: String
      let sequence: UInt64
    }
    let channel: URL
    let identity: ProcessLifecycleIdentity

    func read(requireCompleteTail: Bool = false) throws -> [Entry] {
      var entries: [Entry] = []
      var found = false
      var bytes = 0
      func account(_ line: Data) throws {
        bytes += line.count
        guard bytes <= 64 * 1024 * 1024 else {
          throw CKSimError("Merged journal exceeds 64 MiB.")
        }
      }
      let directory = channel.appending(path: "process/\(identity.runID)")
      if FileManager.default.fileExists(atPath: directory.path) {
        for file in try FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: nil
        ).sorted(by: { $0.path < $1.path }) {
          guard file.pathExtension == "jsonl",
            let producer = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
            file.lastPathComponent == "\(producer.uuidString).jsonl"
          else { throw CKSimError("Unexpected process journal segment.") }
          var status = stat()
          guard lstat(file.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == getuid(), status.st_nlink == 1, status.st_mode & 0o7777 == 0o600
          else { throw CKSimError("Unsafe process journal segment.") }
          found = true
          var sequence: UInt64 = 0
          var uptime: UInt64 = 0
          for line in try lines(file, requireCompleteTail: requireCompleteTail) {
            try account(line)
            let row = try JSONDecoder().decode(ProcessLifecycleRecord.self, from: line)
            guard row.simulatorID == identity.simulatorID, row.bundleID == identity.bundleID,
              row.runID == identity.runID, row.producerID == producer,
              row.sequence == sequence + 1, row.uptimeNanoseconds >= uptime
            else { throw CKSimError("Inconsistent process journal segment.") }
            sequence = row.sequence
            uptime = row.uptimeNanoseconds
            entries.append(
              Entry(
                line: line, uptimeNanoseconds: uptime, producer: producer.uuidString,
                sequence: sequence))
          }
        }
      }
      let runtime = channel.appending(path: "\(identity.runID)/events.jsonl")
      if FileManager.default.fileExists(atPath: runtime.path) {
        found = true
        var sequence: UInt64 = 0
        var uptime: UInt64 = 0
        var pid: Int?
        for line in try lines(runtime, requireCompleteTail: requireCompleteTail) {
          try account(line)
          let row: RuntimeHeader
          do { row = try JSONDecoder().decode(RuntimeHeader.self, from: line) } catch {
            throw CKSimError(
              "Runtime journal requires valid absolute monotonic timestamps; rebuild the runtime if needed."
            )
          }
          guard row.schemaVersion == 1, row.runID == identity.runID,
            row.bundleID == identity.bundleID, row.pid > 0, pid == nil || pid == row.pid,
            row.sequence == sequence + 1, row.uptimeNanoseconds > 0,
            row.wallTimeMS >= 0, !row.event.isEmpty
          else { throw CKSimError("Inconsistent runtime journal segment.") }
          sequence = row.sequence
          uptime = row.uptimeNanoseconds
          pid = row.pid
          entries.append(
            Entry(
              line: line, uptimeNanoseconds: uptime, producer: "runtime-\(row.pid)",
              sequence: sequence))
        }
      }
      guard found else { throw CKSimError("No journal segments for the requested run.") }
      return entries.sorted {
        if $0.uptimeNanoseconds != $1.uptimeNanoseconds {
          return $0.uptimeNanoseconds < $1.uptimeNanoseconds
        }
        if $0.producer != $1.producer { return $0.producer < $1.producer }
        return $0.sequence < $1.sequence
      }
    }

    private struct RuntimeHeader: Decodable {
      let schemaVersion: Int
      let runID: String
      let bundleID: String
      let pid: Int
      let event: String
      let sequence: UInt64
      let uptimeNanoseconds: UInt64
      let wallTimeMS: Int64
    }

    private func lines(_ file: URL, requireCompleteTail: Bool) throws -> [Data] {
      let descriptor = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
      guard descriptor >= 0 else { throw CKSimError("Cannot open journal segment safely.") }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      defer { try? handle.close() }
      let limit = 16 * 1024 * 1024
      var status = stat()
      guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
        status.st_uid == getuid(), status.st_nlink == 1,
        status.st_size <= limit
      else { throw CKSimError("Unsafe or oversized journal segment.") }
      let data = try handle.read(upToCount: limit + 1) ?? Data()
      guard data.count <= limit else { throw CKSimError("Journal segment exceeds 16 MiB.") }
      guard !requireCompleteTail || data.isEmpty || data.last == 10 else {
        throw CKSimError("Incomplete journal tail; pending delivery outcome is unknown.")
      }
      // A concurrently written or interrupted final row is not yet a complete observation.
      return data.split(separator: 10, omittingEmptySubsequences: false).dropLast().map(Data.init)
    }
  }

  extension ProcessLifecycle {
    /// Serializes final snapshots and cancellation writes across independent host commands.
    func cancellationLease() async throws -> FileHandle {
      let path = file.deletingLastPathComponent().deletingLastPathComponent().appending(
        path: ".\(identity.runID).cancellation-lock")
      let descriptor = open(
        path.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
      guard descriptor >= 0 else { throw CKSimError("Cannot open cancellation lease.") }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      var status = stat()
      guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
        status.st_uid == getuid(), status.st_nlink == 1, status.st_mode & 0o7777 == 0o600
      else {
        try handle.close()
        throw CKSimError("Unsafe cancellation lease.")
      }
      let deadline = ContinuousClock.now + .seconds(60)
      do {
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
          guard errno == EWOULDBLOCK, ContinuousClock.now < deadline else {
            throw CKSimError("Cannot acquire cancellation lease.")
          }
          try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        return handle
      } catch {
        try? handle.close()
        throw error
      }
    }

    /// Retains the launch request until the verified process exits, including exits before hooks exist.
    static func supervise(
      target: Target, container: URL, envelope: PushLaunchEnvelope, environment: [String: String],
      observationTimeout: Duration = .seconds(30),
      clock: some Clock<Duration> = ContinuousClock(),
      hasExited: (Int32) throws -> Bool = { pid in
        if Darwin.kill(pid, 0) == 0 { return false }
        guard errno == ESRCH else { throw CKSimError("Cannot establish launched process exit.") }
        return true
      }
    ) async throws {
      guard envelope.bundleID == target.bundle else {
        throw CKSimError("Launch plan bundle mismatch.")
      }
      let channel = container.appending(path: "Documents/.callkit-simulator")
      guard let simulator = UUID(uuidString: target.device) else {
        throw CKSimError("Require a resolved simulator UUID.")
      }
      let identity = try ProcessLifecycleIdentity(
        simulatorID: simulator, bundleID: target.bundle, runID: envelope.runID)
      let journal = try ProcessLifecycle(channel: channel, identity: identity)
      let snapshot = ProcessJournal(channel: channel, identity: identity)
      for id in envelope.deliveryIDs {
        try await journal.record(.launchScheduled, requestID: envelope.id, pushID: id)
      }
      try await journal.record(.launchRequested, requestID: envelope.id)
      let output: ProcessOutput
      do {
        output = try target.simctl.run(
          ["launch", target.device, target.bundle], environment, Simctl.limit)
        guard output.status == 0 else {
          throw CKSimError("Simulator launch failed: \(output.diagnostic)")
        }
      } catch {
        try await journal.record(.launchFailed, requestID: envelope.id)
        throw error
      }
      let prefix = "\(target.bundle): "
      let response = output.output.trimmingCharacters(in: .whitespacesAndNewlines)
      guard response.hasPrefix(prefix), let pid = Int32(response.dropFirst(prefix.count)), pid > 0
      else {
        throw CKSimError("Simulator launch returned no verifiable process identity.")
      }
      let deadline = clock.now.advanced(by: observationTimeout)
      var observedSession = false
      var timedOut = false
      while true {
        try Task.checkCancellation()
        guard
          URL(
            filePath: try target.simctl("get_app_container", target.device, target.bundle, "data")
          ).standardizedFileURL.path == container.standardizedFileURL.path
        else {
          throw CKSimError("Launched application container changed.")
        }
        let query = try target.simctl.run(
          ["spawn", target.device, "launchctl", "list"],
          ProcessInfo.processInfo.environment.merging(["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": ""]) {
            $1
          }, Simctl.limit)
        guard query.status == 0, query.standardError.isEmpty else {
          throw CKSimError("Cannot observe launched app service.")
        }
        let service = try AppService.read(query.standardOutput, bundle: target.bundle)
        guard service == nil || service?.pid == Int(pid) else {
          throw CKSimError("Launched process was replaced; exit is unverified.")
        }
        let sessionFile = channel.appending(path: "session.json")
        if exists(sessionFile) {
          let session = try PublishedSession(channel: channel, bundle: target.bundle).session
          if session.runID == envelope.runID {
            guard session.pid == Int(pid) else {
              throw CKSimError("Launched runtime PID mismatch.")
            }
            observedSession = true
          } else if observedSession {
            throw CKSimError("Launched runtime session was replaced.")
          }
        } else if observedSession {
          throw CKSimError("Launched runtime session disappeared.")
        }
        if service == nil, try hasExited(pid) {
          try await journal.record(.exited, pid: Int(pid), requestID: envelope.id, cause: .unknown)
          let lease = try await journal.cancellationLease()
          defer { try? lease.close() }
          for id in try snapshot.pendingLaunchDeliveries(envelope, pid: Int(pid)) {
            try await journal.record(
              .cancelled, pid: Int(pid), requestID: envelope.id, pushID: id, cause: .unknown)
          }
          return
        }
        if !timedOut, clock.now >= deadline {
          let readiness = try snapshot.readiness(pid: Int(pid))
          if readiness.registry == nil {
            try await journal.record(.registryMissing, pid: Int(pid), requestID: envelope.id)
          }
          if readiness.handler == nil {
            try await journal.record(.handlerMissing, pid: Int(pid), requestID: envelope.id)
          }
          timedOut = true
        }
        try await clock.sleep(for: .milliseconds(100))
      }
    }
  }

  extension ProcessJournal {
    /// Includes copies that never reached runtime scheduling, for example an exit during startup.
    func pendingLaunchDeliveries(_ envelope: PushLaunchEnvelope, pid: Int) throws -> [UUID] {
      let pending = try pendingDeliveries(pid: pid)
      for delivery in pending where envelope.deliveryIDs.contains(delivery.pushID) {
        guard delivery.requestID == envelope.id else {
          throw CKSimError("Launch request correlation mismatch.")
        }
      }
      let ids = Set(pending.map(\.pushID))
      return envelope.deliveryIDs.filter { ids.contains($0) }
    }

    /// Projects validated, invocation-local observations; missing boundaries remain absent.
    func readiness(pid: Int) throws -> ProcessReadinessSnapshot {
      struct Boundary: Decodable {
        let event: String
        let boundarySource: String?
        let generation: Int?
      }
      var result = ProcessReadinessSnapshot()
      for entry in try read() {
        let row = try JSONDecoder().decode(Boundary.self, from: entry.line)
        if !entry.producer.hasPrefix("runtime-") {
          if row.event == ProcessLifecycleEvent.launchRequested.rawValue {
            result.launchRequested = entry.uptimeNanoseconds
          }
          if row.event == ProcessLifecycleEvent.registryMissing.rawValue {
            result.registryTimedOut = true
          }
          if row.event == ProcessLifecycleEvent.handlerMissing.rawValue {
            result.handlerTimedOut = true
          }
          continue
        }
        guard entry.producer == "runtime-\(pid)" else {
          throw CKSimError("Readiness PID mismatch.")
        }
        switch row.event {
        case "process.entered":
          guard result.entered == nil, row.boundarySource == "runtime-preparation" else {
            throw CKSimError("Invalid process entry boundary.")
          }
          result.entered = entry.uptimeNanoseconds
        case "runtime.ready":
          guard let entered = result.entered, result.runtimeReady == nil,
            entry.uptimeNanoseconds >= entered, row.boundarySource == "hooks-installed"
          else { throw CKSimError("Invalid runtime readiness boundary.") }
          result.runtimeReady = entry.uptimeNanoseconds
        case "push.registryReady":
          guard let entered = result.entered, entry.uptimeNanoseconds >= entered,
            result.registry == nil,
            row.boundarySource == ProcessReadinessSnapshot.Source.registryQueue.rawValue
          else {
            throw CKSimError("Unverified registry readiness source.")
          }
          result.registry = .init(
            uptimeNanoseconds: entry.uptimeNanoseconds, source: .registryQueue)
        case "app.handlerReady":
          guard let entered = result.entered, entry.uptimeNanoseconds >= entered,
            row.boundarySource == ProcessReadinessSnapshot.Source.handlerAttachment.rawValue,
            let generation = row.generation, generation > (result.handler?.generation ?? 0)
          else { throw CKSimError("Handler readiness lacks generation identity.") }
          result.handler = .init(
            uptimeNanoseconds: entry.uptimeNanoseconds, source: .handlerAttachment,
            generation: generation)
        default: break
        }
      }
      return result
    }
  }
#endif
