import Foundation
import AVFAudio
import LiveKit

private enum Failure: Error { case assertion(String) }
@main
struct LiveKitAdapterTests {
  @MainActor static func main() async throws {
    for reset in [false, true] {
      let backend = AudioManager.shared
      let adapter = LiveKitMediaAdapter()
      let operations = AudioAdapterOperations()
      var complete = false
      var errors: [String] = []
      operations.onError = { errors.append($0) }
      backend.armSuspendedPreparation()
      operations.enqueue { try await adapter.prepare() }
      try await eventually { backend.preparationStarted }
      adapter.setSystemAudioAuthorization(true)
      operations.enqueue { try await adapter.didActivate(AVAudioSession()) }
      adapter.setSystemAudioAuthorization(false)
      if reset { operations.enqueue { try await adapter.prepare() } }
      else { operations.enqueue { try await adapter.didDeactivate(AVAudioSession()) } }
      operations.enqueue { complete = true }
      backend.releasePreparation()
      try await eventually { complete }
      guard errors.isEmpty, backend.calls == [.none, .none, .none],
            !backend.audioSession.isAutomaticConfigurationEnabled else {
        throw Failure.assertion("Queued activation must remain gated after genuine deactivation/reset.")
      }
    }
    let adapter = LiveKitMediaAdapter()
    let backend = AudioManager.shared
    backend.clear()
    try await adapter.prepare()
    adapter.setSystemAudioAuthorization(true)
    try await adapter.didActivate(AVAudioSession())
    adapter.setSystemAudioAuthorization(false)
    try await adapter.didDeactivate(AVAudioSession())
    guard backend.calls == [.none, .default, .none] else {
      throw Failure.assertion("Current genuine authorization must permit pending media, then gate it.")
    }
    print("LiveKit source host checks passed: queued activation after deactivate/reset stays gated; healthy authorization permits then gates media (facade backend only).")
  }
  @MainActor private static func eventually(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !predicate() {
      guard ContinuousClock.now < deadline else { throw Failure.assertion("Host adapter operation did not complete.") }
      await Task.yield()
    }
  }
}
