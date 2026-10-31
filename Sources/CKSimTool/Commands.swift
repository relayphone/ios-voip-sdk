#if os(macOS)
  import ArgumentParser
  import CKSimProtocol
  import Foundation

  /// The entry point of the `cksim` executable.
  public enum CKSimTool {
    public static func main() async {
      await CKSim.main()
    }
  }

  /// Options that every command takes, before or after the command's name.
  struct GlobalOptions: ParsableArguments {
    @Option(help: "The simulator's UUID, or `booted` for the only booted simulator.")
    var simulator = "booted"
    @Option(help: "The target app's bundle identifier.")
    var bundle: String?
    @Option(help: "The runtime package. Defaults to the directory that contains cksim.")
    var runtimeDir: String?
    @Option(
      help: "Reuse a discovered target data container; its simulator and session are checked.")
    var appContainer: String?
    @Option(help: "Seconds to wait for the runtime's response.")
    var timeout: Double = 15
    @Option(help: "Keep the exact session, request and response in this new file.")
    var commandReceipt: String?
  }

  /// What a command needs from its environment. Tests replace it.
  struct Tool: Sendable {
    @TaskLocal static var current = Tool()

    var simctl = Simctl.live
    var stateDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(
      path: ".local/state/callkit-simulator")
    /// Where `cksim` itself is, which is a runtime package unless `--runtime-dir` says otherwise.
    var executableDirectory =
      Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
      ?? URL(filePath: ".")
    var write: @Sendable (String) -> Void = { print($0) }
  }

  /// The checks that every command shares.
  extension GlobalOptions {
    func validate(command: String, launching: Bool = false) throws {
      let named = bundle.map { name in
        !name.isEmpty
          && name.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-")
          }
      }
      if appContainer != nil,
        ["install", "uninstall", "repair", "launch"].contains(command) || launching
      {
        throw ValidationError(
          "--app-container is only supported for running-app controls, watch and inspect")
      }
      if named == false || (bundle == nil && !["uninstall", "repair"].contains(command))
        || !(timeout > 0 && timeout <= 120)
      {
        throw ValidationError("Require a bundle identifier and timeout in (0,120].")
      }
    }

    var runtimeDirectory: URL {
      runtimeDir.map { URL(filePath: $0) } ?? Tool.current.executableDirectory
    }

    var responseLimit: Duration { .milliseconds(Int(timeout * 1000)) }

    func target(_ device: String) -> Target {
      Target(
        simctl: Tool.current.simctl, device: device, bundle: bundle ?? "",
        appContainer: appContainer.map { URL(filePath: $0) })
    }

    /// Checks the package unless the command doesn't use it, then resolves the simulator.
    func device(command: String) throws -> String {
      if !["uninstall", "repair", "watch"].contains(command) {
        try RuntimePackage.validate(runtimeDirectory)
      }
      return try Tool.current.simctl.simulator(simulator)
    }

    /// Prints a result as JSON, and fails the command if it reports no success.
    func finish(_ result: [String: Any]) throws {
      let data = try JSONSerialization.data(
        withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
      Tool.current.write(String(decoding: data, as: UTF8.self))
      if result["success"] as? Bool == false { throw ExitCode.failure }
    }

    /// Sends a control to the target's runtime and prints its response.
    func control(_ operation: ControlRequest.Operation, command: String) async throws {
      try validate(command: command)
      let device = try device(command: command)
      let mailbox = Mailbox(
        target: target(device), timeout: responseLimit,
        receipt: commandReceipt.map { URL(filePath: $0) })
      try finish(try await mailbox.send(operation))
    }
  }

  /// Runs a command, reporting a failure as `cksim` always has: its message on standard error and
  /// exit status 1.
  func reporting(_ body: () async throws -> Void) async throws {
    do {
      try await body()
    } catch let error as CKSimError {
      FileHandle.standardError.write(Data("\(error.description)\n".utf8))
      throw ExitCode.failure
    } catch let error as CocoaError {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      throw ExitCode.failure
    } catch let error as ControlRequest.ValidationError {
      FileHandle.standardError.write(Data("Invalid control: \(error)\n".utf8))
      throw ExitCode.failure
    }
  }

  struct CKSim: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "cksim",
      abstract: "Control the simulator runtime in one running simulator app.",
      subcommands: [
        Watch.self, Inspect.self, Status.self, Events.self, InspectAdapter.self, Install.self,
        Uninstall.self, Repair.self, Launch.self, Reset.self, Answer.self, Decline.self,
        End.self, Unmerge.self, Merge.self, Hold.self, Mute.self, Tones.self,
        HoldAndAccept.self, EndAndAccept.self, EndHeldAndAccept.self, Push.self, Faults.self,
        IncomingFilter.self,
      ])

    /// Runs `cksim` with arguments in which the shared options may come before the command.
    static func main() async {
      await main(arguments(CommandLine.arguments.dropFirst()))
    }

    /// Moves shared options that come before the command's name to after it, where the command
    /// reads them.
    static func arguments(_ arguments: some Collection<String>) -> [String] {
      let options: Set = [
        "--simulator", "--bundle", "--runtime-dir", "--app-container", "--timeout",
        "--command-receipt",
      ]
      var leading: [String] = []
      var rest = Array(arguments)
      while let first = rest.first {
        let name = first.split(separator: "=", maxSplits: 1).first.map(String.init) ?? first
        guard options.contains(name) else { break }
        leading.append(rest.removeFirst())
        if !first.contains("="), let value = rest.first {
          leading.append(value)
          rest.removeFirst()
        }
      }
      guard let command = rest.first else { return leading }
      return [command] + leading + rest.dropFirst()
    }
  }

  /// A control whose only parameter is a call.
  protocol CallControlCommand: AsyncParsableCommand {
    var options: GlobalOptions { get }
    var call: String { get }
    func control(_ call: UUID) throws -> ControlRequest.CallControl
  }

  extension CallControlCommand {
    func run() async throws {
      try await reporting {
        try options.validate(command: Self.configuration.commandName ?? "")
        guard let id = UUID(uuidString: call) else {
          throw CKSimError("badly formed hexadecimal UUID string")
        }
        try await options.control(
          .call(try control(id)), command: Self.configuration.commandName ?? "")
      }
    }
  }

  /// Parses a UUID argument.
  func callID(_ text: String) throws -> UUID {
    guard let id = UUID(uuidString: text) else {
      throw CKSimError("badly formed hexadecimal UUID string")
    }
    return id
  }

  enum Truth: String, ExpressibleByArgument, CaseIterable {
    case `true`, `false`
    var value: Bool { self == .true }
  }

  extension CKSim {
    struct Watch: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Follow the shared runtime timeline (Ctrl-C to stop).")
      @OptionGroup var options: GlobalOptions
      @Flag(help: "Emit the original versioned events as JSONL.") var json = false
      @Option(help: "Skip this run's events through this sequence.") var after = 0
      @Option(help: "Stop after this many seconds (for CI captures).") var duration: Double?

      func validate() throws {
        guard after >= 0, duration.map({ $0 > 0 && $0 <= 86_400 }) ?? true else {
          throw ValidationError("watch requires nonnegative --after and --duration in (0,86400].")
        }
      }

      func run() async throws {
        try await reporting {
          try options.validate(command: "watch")
          let device = try options.device(command: "watch")
          try await watch(
            channel: options.target(device).channel(), bundle: options.bundle ?? "",
            json: json, after: after, duration: duration.map { .milliseconds(Int($0 * 1000)) })
        }
      }
    }

    struct Inspect: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Launch the separate SwiftUI simulator inspector.")
      @OptionGroup var options: GlobalOptions
      @Option(help: "The built CKSimInspector.app.") var app: String
      @Option(help: "Reuse a separate booted simulator instead of creating a disposable display.")
      var inspectorSimulator: String?
      @Flag(help: "Allow a supplied shared display for a bounded, background-capable test fixture.")
      var allowSharedSimulator = false

      func validate() throws {
        if allowSharedSimulator && inspectorSimulator == nil {
          throw ValidationError(
            "--allow-shared-simulator requires an explicit --inspector-simulator")
        }
      }

      func run() async throws {
        try await reporting {
          try options.validate(command: "inspect")
          let device = try options.device(command: "inspect")
          try await inspect(
            target: options.target(device), timeout: options.responseLimit,
            app: URL(filePath: app), display: inspectorSimulator,
            allowShared: allowSharedSimulator)
        }
      }
    }

    struct Status: AsyncParsableCommand {
      @OptionGroup var options: GlobalOptions
      func run() async throws {
        try await reporting { try await options.control(.status, command: "status") }
      }
    }

    struct Events: AsyncParsableCommand {
      @OptionGroup var options: GlobalOptions
      func run() async throws {
        try await reporting { try await options.control(.events, command: "events") }
      }
    }

    struct InspectAdapter: AsyncParsableCommand {
      static let configuration = CommandConfiguration(commandName: "inspect-adapter")
      @OptionGroup var options: GlobalOptions
      func run() async throws {
        try await reporting {
          try await options.control(.inspectAdapter, command: "inspect-adapter")
        }
      }
    }

    struct Reset: AsyncParsableCommand {
      @OptionGroup var options: GlobalOptions
      func run() async throws {
        try await reporting { try await options.control(.reset, command: "reset") }
      }
    }

    struct Install: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Add the runtime's loader to the simulator's launchd environment for the bundle.")
      @OptionGroup var options: GlobalOptions
      func run() async throws {
        try await reporting {
          try options.validate(command: "install")
          let device = try options.device(command: "install")
          try options.finish(
            try installation(device).install(
              runtime: options.runtimeDirectory, bundle: options.bundle ?? ""))
        }
      }
    }

    struct Uninstall: AsyncParsableCommand {
      @OptionGroup var options: GlobalOptions
      func run() async throws {
        try await reporting {
          try options.validate(command: "uninstall")
          try options.finish(try installation(try options.device(command: "uninstall")).uninstall())
        }
      }
    }

    struct Repair: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Restore the simulator's launchd environment after an interrupted installation.")
      @OptionGroup var options: GlobalOptions
      func run() async throws {
        try await reporting {
          try options.validate(command: "repair")
          try options.finish(try installation(try options.device(command: "repair")).repair())
        }
      }
    }

    struct Launch: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        abstract: "Launch the app with the runtime injected.")
      @OptionGroup var options: GlobalOptions
      func run() async throws {
        try await reporting {
          try options.validate(command: "launch")
          let device = try options.device(command: "launch")
          try options.finish(
            try launch(
              simctl: Tool.current.simctl, device: device, bundle: options.bundle ?? "",
              runtime: options.runtimeDirectory))
        }
      }
    }

    struct Answer: CallControlCommand {
      @OptionGroup var options: GlobalOptions
      @Argument var call: String
      func control(_ call: UUID) -> ControlRequest.CallControl { .answer(call) }
    }

    struct Decline: CallControlCommand {
      @OptionGroup var options: GlobalOptions
      @Argument var call: String
      func control(_ call: UUID) -> ControlRequest.CallControl { .decline(call) }
    }

    struct End: CallControlCommand {
      @OptionGroup var options: GlobalOptions
      @Argument var call: String
      func control(_ call: UUID) -> ControlRequest.CallControl { .end(call) }
    }

    struct Unmerge: CallControlCommand {
      @OptionGroup var options: GlobalOptions
      @Argument var call: String
      @Flag var application = false
      func control(_ call: UUID) -> ControlRequest.CallControl {
        .unmerge(call, origin: application ? .application : .system)
      }
    }

    struct Merge: CallControlCommand {
      @OptionGroup var options: GlobalOptions
      @Argument var call: String
      @Option var groupWithCall: String
      @Flag var application = false
      func control(_ call: UUID) throws -> ControlRequest.CallControl {
        .merge(call, with: try callID(groupWithCall), origin: application ? .application : .system)
      }
    }

    struct Hold: CallControlCommand {
      @OptionGroup var options: GlobalOptions
      @Argument var call: String
      @Option var held: Truth
      @Flag var application = false
      func control(_ call: UUID) -> ControlRequest.CallControl {
        .hold(call, held: held.value, origin: application ? .application : .system)
      }
    }

    struct Mute: CallControlCommand {
      @OptionGroup var options: GlobalOptions
      @Argument var call: String
      @Option var muted: Truth
      func control(_ call: UUID) -> ControlRequest.CallControl { .mute(call, muted: muted.value) }
    }

    struct Tones: CallControlCommand {
      @OptionGroup var options: GlobalOptions
      @Argument var call: String
      @Option var digits: String
      func validate() throws {
        guard (1...64).contains(digits.utf8.count),
          digits.utf8.allSatisfy({ "0123456789*#ABCDabcd".utf8.contains($0) })
        else { throw ValidationError("digits must contain 1-64 DTMF characters") }
      }
      func control(_ call: UUID) -> ControlRequest.CallControl { .tones(call, digits: digits) }
    }

    struct HoldAndAccept: CallControlCommand {
      static let configuration = CommandConfiguration(commandName: "hold-and-accept")
      @OptionGroup var options: GlobalOptions
      @Argument var call: String
      @Option var activeCall: String
      func control(_ call: UUID) throws -> ControlRequest.CallControl {
        .holdAndAccept(call, active: try callID(activeCall))
      }
    }

    struct EndAndAccept: CallControlCommand {
      static let configuration = CommandConfiguration(commandName: "end-and-accept")
      @OptionGroup var options: GlobalOptions
      @Argument var call: String
      @Option var activeCall: String
      func control(_ call: UUID) throws -> ControlRequest.CallControl {
        .endAndAccept(call, active: try callID(activeCall))
      }
    }

    struct EndHeldAndAccept: CallControlCommand {
      static let configuration = CommandConfiguration(commandName: "end-held-and-accept")
      @OptionGroup var options: GlobalOptions
      @Argument var call: String
      @Option var activeCall: String
      @Option var heldCall: String
      func control(_ call: UUID) throws -> ControlRequest.CallControl {
        .endHeldAndAccept(call, active: try callID(activeCall), held: try callID(heldCall))
      }
    }

    struct Push: AsyncParsableCommand {
      @OptionGroup var options: GlobalOptions
      @Option var payloadFile: String
      @Option var mustReport: Truth
      @Flag(help: "Stage a push and launch a stopped SDK app (no DYLD injection).")
      var launch = false
      @Option var runID: String?
      @Option var launchReceipt: String?

      func validate() throws {
        if launch {
          guard let runID, (1...64).contains(runID.utf8.count),
            runID.utf8.allSatisfy({ isRunIDByte($0) }), launchReceipt != nil
          else {
            throw ValidationError("push --launch requires --run-id and a fresh --launch-receipt")
          }
        }
      }

      func run() async throws {
        try await reporting {
          try options.validate(command: "push", launching: launch)
          if launch {
            let device = try options.device(command: "push")
            try PushLaunch(
              target: options.target(device), runID: runID ?? "", mustReport: mustReport.value,
              payloadFile: URL(filePath: payloadFile),
              receipt: URL(filePath: launchReceipt ?? "")
            ).run()
          }
          let payload = try JSONDecoder().decode(
            PushPayload.self, from: Data(contentsOf: URL(filePath: payloadFile)))
          try await options.control(.push(payload, mustReport: mustReport.value), command: "push")
        }
      }
    }

    struct Faults: AsyncParsableCommand {
      @OptionGroup var options: GlobalOptions
      @Flag var staleAudio = false
      @Option var reportDelayMs: Int?
      @Flag var invalidateDuringHandoff = false
      @Option(help: "Inject code 4 (not produced by iOS 27.0 for LCK), or clear it with 0.")
      var incomingErrorCode: Int?

      func validate() throws {
        if let incomingErrorCode, ![0, 4].contains(incomingErrorCode) {
          throw ValidationError("--incoming-error-code must be 0 or 4")
        }
      }

      /// The faults to change: those named, or, with none named, all of them cleared.
      var changes: [ControlRequest.FaultChange] {
        var changes: [ControlRequest.FaultChange] = []
        if staleAudio { changes.append(.staleAudio(true)) }
        if let reportDelayMs { changes.append(.reportCallbackDelayMS(reportDelayMs)) }
        if invalidateDuringHandoff { changes.append(.invalidateDuringHandoff(true)) }
        if let incomingErrorCode { changes.append(.incomingErrorCode(incomingErrorCode)) }
        return changes.isEmpty
          ? [
            .staleAudio(false), .reportCallbackDelayMS(0), .invalidateDuringHandoff(false),
            .incomingErrorCode(0),
          ] : changes
      }

      func run() async throws {
        try await reporting { try await options.control(.faults(changes), command: "faults") }
      }
    }

    struct IncomingFilter: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "incoming-filter", abstract: "Set the simulator's incoming-report filter.")
      @OptionGroup var options: GlobalOptions
      @Option(
        help: ArgumentHelp(
          "Persistent filter for subsequent reports; codes 5–7 are unverified.",
          valueName: ControlRequest.FilterReason.allCases.map(\.rawValue).joined(separator: "|")),
        transform: { value in
          guard let reason = ControlRequest.FilterReason(rawValue: value) else {
            throw ValidationError("invalid choice: \(value)")
          }
          return reason
        })
      var reason: ControlRequest.FilterReason
      func run() async throws {
        try await reporting {
          try await options.control(.incomingFilter(reason), command: "incoming-filter")
        }
      }
    }
  }

  private func installation(_ device: String) -> Installation {
    Installation(
      simctl: Tool.current.simctl, device: device, stateDirectory: Tool.current.stateDirectory)
  }

  func isRunIDByte(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45
      || byte == 95
  }
#endif
