#if os(macOS)
  import ArgumentParser
  import CKSimProtocol
  import Foundation

  extension CKSim {
    struct ExecutionScenario: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
        commandName: "execution-scenario",
        abstract: "Configure an explicit execution fixture once for this invocation.")
      @OptionGroup var options: GlobalOptions
      @Option(help: "A JSON ExecutionScenarioConfiguration with explicit unverified allowances.")
      var configurationFile: String

      mutating func run() async throws {
        try await reporting {
          let url = URL(filePath: configurationFile)
          guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 8192 else {
            throw CKSimError("Execution scenario configuration exceeds 8192 bytes.")
          }
          let config = try JSONDecoder().decode(
            ExecutionScenarioConfiguration.self, from: Data(contentsOf: url))
          try await options.control(.executionScenario(config), command: "execution-scenario")
        }
      }
    }
  }
#endif
