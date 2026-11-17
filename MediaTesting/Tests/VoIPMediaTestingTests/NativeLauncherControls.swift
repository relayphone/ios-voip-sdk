#if DEBUG && os(iOS) && targetEnvironment(simulator)
  import Foundation
  import Testing

  /// Opt-in process controls verify that the host preserves failure and kills a stalled runner.
  @Suite(.serialized)
  struct NativeLauncherControls {
    private enum Mode: String { case success, failure, hang }
    private static var mode: Mode? {
      ProcessInfo.processInfo.environment["NATIVE_LAUNCHER_CONTROL"].flatMap(Mode.init(rawValue:))
    }

    @Test(.enabled(if: mode != nil), .timeLimit(.minutes(1)))
    func processOutcome() async throws {
      let mode = try #require(Self.mode)
      FileHandle.standardOutput.write(Data("NATIVE_LAUNCHER_CONTROL \(mode.rawValue)\n".utf8))
      switch mode {
      case .success: return
      case .failure: Issue.record("Intentional native launcher failure control")
      case .hang: try await Task.sleep(for: .seconds(30))
      }
    }
  }
#endif
