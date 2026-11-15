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

  /// A bounded offline snapshot: host segments are available even without a runtime session.
  struct ProcessJournal {
    struct Entry {
      let line: Data
      let uptimeNanoseconds: UInt64
      let producer: String
      let sequence: UInt64
    }
    let channel: URL
    let identity: ProcessLifecycleIdentity

    func read() throws -> [Entry] {
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
          for line in try lines(file) {
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
        for line in try lines(runtime) {
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

    private func lines(_ file: URL) throws -> [Data] {
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
      // A concurrently written or interrupted final row is not yet a complete observation.
      return data.split(separator: 10, omittingEmptySubsequences: false).dropLast().map(Data.init)
    }
  }
#endif
