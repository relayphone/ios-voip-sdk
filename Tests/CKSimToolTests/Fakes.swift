#if os(macOS)
  import ArgumentParser
  import CKSimProtocol
  import CryptoKit
  import Foundation
  import Synchronization
  import Testing

  @testable import CKSimTool

  let device = "00000000-0000-0000-0000-000000000001"
  let bundle = "dev.example.app"
  let call = UUID(uuidString: "A7E390AF-6B78-4190-B946-26D9C6438584")!

  /// A temporary directory that the test removes when it ends.
  final class Scratch: Sendable {
    let url: URL

    init() throws {
      url = FileManager.default.temporaryDirectory.appending(path: "cksim-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
  }

  /// A simulator for `simctl`: its launchd environment, its app containers and every call.
  final class FakeSimulator: Sendable {
    struct State {
      var environment: [String: String] = [:]
      var calls: [[String]] = []
      var containers: [String: URL] = [:]
      var launches: [[String: String]] = []
      var serviceTable = "PID\tStatus\tLabel\n-\t0\tcom.apple.example\n"
    }

    let state = Mutex(State())

    var calls: [[String]] { state.withLock { $0.calls } }
    var environment: [String: String] { state.withLock { $0.environment } }

    func set(_ key: String, _ value: String?) {
      state.withLock { $0.environment[key] = value }
    }

    var simctl: Simctl {
      Simctl { [self] arguments, environment, _ in
        state.withLock { state in
          state.calls.append(arguments)
          var output = ProcessOutput()
          func reply(_ text: String) { output.standardOutput = Data(text.utf8) }
          switch Array(arguments.prefix(4)) {
          case ["spawn", device, "launchctl", "getenv"]:
            if let value = state.environment[arguments[4]] { reply(value + "\n") }
          case ["spawn", device, "launchctl", "setenv"]:
            state.environment[arguments[4]] = arguments[5]
          case ["spawn", device, "launchctl", "unsetenv"]:
            state.environment[arguments[4]] = nil
          case ["spawn", device, "launchctl", "list"]: reply(state.serviceTable)
          default:
            if arguments.first == "get_app_container",
              let container = state.containers[arguments[2]]
            {
              reply(container.path(percentEncoded: false) + "\n")
            } else if arguments.first == "launch" {
              state.launches.append(environment ?? [:])
              reply("\(arguments.last ?? ""): 4242\n")
            } else {
              output.status = 1
              output.standardError = Data("unexpected simctl \(arguments)".utf8)
            }
          }
          return output
        }
      }
    }
  }

  /// A runtime package with placeholder files and a correct manifest.
  func makePackage(in directory: URL) throws -> URL {
    let package = directory.appending(path: "package")
    try FileManager.default.createDirectory(
      at: package.appending(path: "profiles"), withIntermediateDirectories: true)
    var files: [String: String] = [:]
    for name in RuntimePackage.required.sorted() {
      let data = Data((name == "VERSION" ? "0.1.1\n" : "placeholder \(name)").utf8)
      try data.write(to: package.appending(path: name))
      files[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "version": "0.1.1", "files": files,
    ]).write(to: package.appending(path: "build-info.json"))
    return package
  }

  /// An app's data container in which a runtime published its session and mailbox.
  struct FakeApp {
    static let runID = "fake-run"
    static let pid = 12_345

    let container: URL
    var channel: URL { container.appending(path: "Documents/.callkit-simulator") }
    var mailbox: URL { channel.appending(path: Self.runID) }

    init(in directory: URL, session: [String: Any]? = nil) throws {
      container = directory.appending(
        path: "Devices/\(device)/data/Containers/Data/Application/\(UUID().uuidString)")
      for folder in ["requests", "responses"] {
        try FileManager.default.createDirectory(
          at: channel.appending(path: "\(Self.runID)/\(folder)"), withIntermediateDirectories: true)
      }
      try JSONSerialization.data(
        withJSONObject: session ?? [
          "schemaVersion": 1, "bundleID": bundle, "pid": Self.pid, "runID": Self.runID,
          "profile": "ios-27.0", "controlTransport": "directory-watch-v1",
        ]
      ).write(to: channel.appending(path: "session.json"))
      FileManager.default.createFile(
        atPath: mailbox.appending(path: "events.jsonl").path(), contents: Data())
    }

    /// Appends journal entries with the next sequences.
    func append(_ events: [[String: Any]]) throws {
      let file = mailbox.appending(path: "events.jsonl")
      let handle = try FileHandle(forWritingTo: file)
      defer { try? handle.close() }
      var sequence = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").count
      for fields in events {
        sequence += 1
        var entry: [String: Any] = [
          "schemaVersion": 1, "runID": Self.runID, "pid": Self.pid, "bundleID": bundle,
          "sequence": sequence, "t_ms": sequence * 10, "wallTimeMS": 1_000 + sequence,
        ]
        entry.merge(fields) { $1 }
        var line = try JSONSerialization.data(withJSONObject: entry, options: .sortedKeys)
        line.append(10)
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
      }
    }

    /// Answers the mailbox's requests as the runtime does, until the task is cancelled. The
    /// closure can change a response before it's written.
    func respond(
      _ change: @escaping @Sendable (ControlRequest, inout [String: Any]) -> Void = { _, _ in }
    ) -> Task<Void, Never> {
      let requests = mailbox.appending(path: "requests")
      let responses = mailbox.appending(path: "responses")
      return Task.detached {
        while !Task.isCancelled {
          let files =
            (try? FileManager.default.contentsOfDirectory(
              at: requests, includingPropertiesForKeys: nil))
            ?? []
          for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
              let request = try? ControlRequest.decode(data)
            else { continue }
            try? FileManager.default.removeItem(at: file)
            let result: ControlResult =
              switch request.operation {
              case .call: .actions(actionIDs: [UUID()], transactionID: UUID())
              case .push: .push(pushID: request.id)
              case .faults(let changes):
                .faults(
                  incomingErrorCode: changes.compactMap {
                    if case .incomingErrorCode(let code) = $0 { code } else { nil }
                  }.first ?? 0)
              default: .events("")
              }
            let response = ControlResponse(
              id: request.id, target: request.target, outcome: .success(result))
            guard
              var object = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(response))
                as? [String: Any]
            else { continue }
            change(request, &object)
            let staged = responses.appending(path: "\(request.id.uuidString).tmp")
            try? JSONSerialization.data(withJSONObject: object).write(to: staged)
            try? FileManager.default.moveItem(
              at: staged, to: responses.appending(path: "\(request.id.uuidString).json"))
          }
          try? await Task.sleep(for: .milliseconds(5))
        }
      }
    }
  }

  /// Runs a command line with the fake simulator, and returns what it printed and whether it
  /// succeeded.
  func run(
    _ arguments: [String], simulator: FakeSimulator, stateDirectory: URL? = nil,
    executableDirectory: URL? = nil
  ) async -> (output: [String], status: Int32) {
    let printed = Mutex([String]())
    var tool = Tool()
    tool.simctl = simulator.simctl
    tool.write = { line in printed.withLock { $0.append(line) } }
    if let stateDirectory { tool.stateDirectory = stateDirectory }
    if let executableDirectory { tool.executableDirectory = executableDirectory }
    let status: Int32 = await Tool.$current.withValue(tool) {
      do {
        var command = try CKSim.parseAsRoot(CKSim.arguments(arguments))
        if var command = command as? any AsyncParsableCommand {
          try await command.run()
        } else {
          try command.run()
        }
        return 0
      } catch {
        return CKSim.exitCode(for: error).rawValue
      }
    }
    return (printed.withLock { $0 }, status)
  }
#endif
