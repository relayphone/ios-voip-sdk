#if os(macOS)
  import ArgumentParser
  import CKSimProtocol
  import Foundation

  extension CKSim {
    struct ProcessControl: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "process", abstract: "Control a verified simulator application process.",
        subcommands: [Kill.self, Suspend.self])

      struct Suspend: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
          abstract: "Suspend a verified run, then wake it from the host after a bounded interval.")
        @OptionGroup var options: GlobalOptions
        @Option(help: "The exact runtime invocation to suspend.") var runID: String
        @Option(help: "Explicit host wake delay in 1...120000 ms; not a measured iOS allowance.")
        var resumeAfterMS: Int

        func validate() throws {
          try options.validate(command: "process")
          guard (1...64).contains(runID.utf8.count), runID.utf8.allSatisfy(isRunIDByte),
            (1...120_000).contains(resumeAfterMS)
          else {
            throw ValidationError("Require a valid --run-id and --resume-after-ms in 1...120000.")
          }
        }

        func run() async throws {
          try await reporting {
            let receipt = try options.newProcessReceipt()
            let device = try Tool.current.simctl.simulator(options.simulator)
            let interrupt = Interrupt()
            let result = try await ProcessSuspension.run(
              target: options.target(device), runID: runID, duration: .milliseconds(resumeAfterMS),
              timeout: options.responseLimit, interrupted: { interrupt.happened })
            try options.writeProcessReceipt(result, to: receipt)
          }
        }
      }

      struct Kill: AsyncParsableCommand {
        enum Cause: String, ExpressibleByArgument, Sendable {
          case abrupt
          case userRequested = "user-requested"
          var processCause: ProcessExitCause {
            switch self {
            case .abrupt: .abrupt
            case .userRequested: .userRequested
            }
          }
        }
        static let configuration = CommandConfiguration(
          abstract: "Stop the requested run and confirm its service has exited.")
        @OptionGroup var options: GlobalOptions
        @Option(help: "The exact runtime run identifier to stop.") var runID: String
        @Option(help: "abrupt or user-requested; neither models persistent force-quit eligibility.")
        var cause: Cause

        func validate() throws {
          try options.validate(command: "process")
          guard (1...64).contains(runID.utf8.count), runID.utf8.allSatisfy(isRunIDByte)
          else {
            throw ValidationError("Require a valid --run-id and --cause abrupt|user-requested.")
          }
        }

        func run() async throws {
          try await reporting {
            let receipt = try options.newProcessReceipt()
            let device = try Tool.current.simctl.simulator(options.simulator)
            let result = try await ProcessLifecycle.kill(
              target: options.target(device), runID: runID,
              cause: cause.processCause, timeout: options.responseLimit)
            try options.writeProcessReceipt(result, to: receipt)
          }
        }
      }
    }
  }

  extension GlobalOptions {
    fileprivate func newProcessReceipt() throws -> URL? {
      let receipt = commandReceipt.map { URL(filePath: $0) }
      if let receipt, exists(receipt) {
        throw CKSimError("Command receipt already exists; inspect before process control.")
      }
      return receipt
    }

    fileprivate func writeProcessReceipt(_ result: some Encodable, to receipt: URL?) throws {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      var bytes = try encoder.encode(result)
      bytes.append(10)
      if let receipt {
        let descriptor = open(
          receipt.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CKSimError("Cannot create process receipt.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        try file.write(contentsOf: bytes)
        try file.synchronize()
      }
      Tool.current.write(String(decoding: bytes, as: UTF8.self))
    }
  }
#endif
