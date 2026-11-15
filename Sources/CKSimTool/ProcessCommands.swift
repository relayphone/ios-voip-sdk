#if os(macOS)
  import ArgumentParser
  import CKSimProtocol
  import Foundation

  extension CKSim {
    struct ProcessControl: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "process", abstract: "Control a verified simulator application process.",
        subcommands: [Kill.self])

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
            let receipt = options.commandReceipt.map { URL(filePath: $0) }
            if let receipt, exists(receipt) {
              throw CKSimError("Command receipt already exists; inspect before killing.")
            }
            let device = try Tool.current.simctl.simulator(options.simulator)
            let result = try await ProcessLifecycle.kill(
              target: options.target(device), runID: runID,
              cause: cause.processCause, timeout: options.responseLimit)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var bytes = try encoder.encode(result)
            bytes.append(10)
            if let receipt {
              let descriptor = open(
                receipt.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
              guard descriptor >= 0 else { throw CKSimError("Cannot create kill receipt.") }
              let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
              defer { try? file.close() }
              try file.write(contentsOf: bytes)
              try file.synchronize()
            }
            Tool.current.write(String(decoding: bytes, as: UTF8.self))
          }
        }
      }
    }
  }
#endif
