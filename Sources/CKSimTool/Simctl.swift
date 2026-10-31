#if os(macOS)
  import Foundation
  import Synchronization

  /// A failure that `cksim` reports on standard error before exiting with status 1.
  struct CKSimError: Error, CustomStringConvertible, Equatable {
    let description: String

    init(_ description: String) { self.description = description }
  }

  /// A finished subprocess.
  struct ProcessOutput: Sendable, Equatable {
    var status: Int32 = 0
    var standardOutput = Data()
    var standardError = Data()

    var output: String { String(decoding: standardOutput, as: UTF8.self) }
    var diagnostic: String { String(decoding: standardError, as: UTF8.self) }
  }

  /// A subprocess that didn't finish within its time limit. It was killed.
  struct ProcessTimeout: Error {}

  /// Runs an executable, collects its output and waits for it, killing it after `timeout`.
  func runProcess(
    _ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
    timeout: Duration
  ) throws -> ProcessOutput {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    if let environment { process.environment = environment }
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    process.standardInput = FileHandle.nullDevice
    let collected = Mutex(ProcessOutput())
    let readers = DispatchGroup()
    for (pipe, isError) in [(output, false), (error, true)] {
      readers.enter()
      DispatchQueue.global().async {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        collected.withLock {
          if isError { $0.standardError = data } else { $0.standardOutput = data }
        }
        readers.leave()
      }
    }
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()
    let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
    if finished.wait(timeout: .now() + seconds) == .timedOut {
      process.terminate()
      if finished.wait(timeout: .now() + 2) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        finished.wait()
      }
      _ = readers.wait(timeout: .now() + 2)
      throw ProcessTimeout()
    }
    readers.wait()
    return collected.withLock {
      $0.status = process.terminationStatus
      return $0
    }
  }

  /// `xcrun simctl`, through a runner that tests replace.
  struct Simctl: Sendable {
    /// How long a simulator command may take before `cksim` gives up on it.
    static let limit = Duration.seconds(60)

    /// Runs `simctl` with the arguments and, if given, the whole environment.
    var run:
      @Sendable (_ arguments: [String], _ environment: [String: String]?, _ timeout: Duration)
        throws -> ProcessOutput

    static let live = Simctl { arguments, environment, timeout in
      try runProcess(
        URL(filePath: "/usr/bin/xcrun"), ["simctl"] + arguments, environment: environment,
        timeout: timeout)
    }

    /// Runs a simulator command and returns its trimmed output, failing on a nonzero status.
    @discardableResult
    func callAsFunction(
      _ arguments: String..., environment: [String: String]? = nil, timeout: Duration = limit
    ) throws -> String {
      var environment = environment
      if arguments.count >= 3, arguments[0] == "spawn", arguments[2] == "launchctl" {
        // Recovery must run even when launchd names a loader deleted from disk. This changes only
        // the control process, never the saved global value.
        environment = (environment ?? ProcessInfo.processInfo.environment).merging([
          "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": ""
        ]) { $1 }
      }
      let result: ProcessOutput
      do {
        result = try run(arguments, environment, timeout)
      } catch is ProcessTimeout {
        throw CKSimError(
          "simctl \(arguments[0]) timed out after \(timeout.components.seconds)s; inspect state before retrying."
        )
      }
      guard result.status == 0 else {
        throw CKSimError(
          "simctl \(arguments[0]) failed: \(result.diagnostic.trimmingCharacters(in: .whitespacesAndNewlines))"
        )
      }
      return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The simulator's UUID: the one given, or the only booted simulator.
    func simulator(_ identifier: String) throws -> String {
      if identifier != "booted" {
        guard let uuid = UUID(uuidString: identifier) else {
          throw CKSimError("Invalid simulator UUID: \(identifier)")
        }
        return uuid.uuidString
      }
      struct Devices: Decodable {
        struct Device: Decodable {
          let udid: String
          let state: String
        }
        let devices: [String: [Device]]
      }
      let list = try JSONDecoder().decode(
        Devices.self, from: Data(self("list", "devices", "booted", "-j").utf8))
      let booted = list.devices.values.flatMap { $0 }.filter { $0.state == "Booted" }
      guard booted.count == 1 else {
        throw CKSimError(
          "Select --simulator UUID explicitly when zero or multiple simulators are booted.")
      }
      return booted[0].udid
    }

    /// A key of the simulator's launchd environment, or `nil` when it's unset. An empty value
    /// stays empty.
    func environment(_ device: String, _ key: String) throws -> String? {
      let environment = ProcessInfo.processInfo.environment.merging([
        "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": ""
      ]) { $1 }
      let result: ProcessOutput
      do {
        result = try run(["spawn", device, "launchctl", "getenv", key], environment, Self.limit)
      } catch is ProcessTimeout {
        throw CKSimError(
          "Reading simulator environment key \(key) timed out after \(Self.limit.components.seconds)s."
        )
      }
      let diagnostic = result.diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
      guard result.status == 0, diagnostic.isEmpty else {
        throw CKSimError("Cannot read simulator environment key \(key): \(diagnostic)")
      }
      // launchctl prints nothing for an unset key and one newline for an empty value.
      guard !result.standardOutput.isEmpty else { return nil }
      var value = result.output
      if value.hasSuffix("\n") { value.removeLast() }
      return value
    }

    /// Sets or, for `nil`, removes a key of the simulator's launchd environment.
    func setEnvironment(_ device: String, _ key: String, _ value: String?) throws {
      if let value {
        try self("spawn", device, "launchctl", "setenv", key, value)
      } else {
        try self("spawn", device, "launchctl", "unsetenv", key)
      }
    }
  }
#endif
