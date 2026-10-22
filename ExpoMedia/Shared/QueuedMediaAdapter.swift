import AVFAudio
import Foundation

/// Objective-C owns its serial queue and framework objects. Only completion
/// results cross this async boundary; no framework Sendable assertion is needed.
@MainActor
final class QueuedMediaAdapter: MediaAdapter {
  private let binding = VSSelectedMediaBinding.shared()

  func setSystemAudioAuthorization(_ active: Bool) {
    binding.setSystemAudioAuthorization(active)
  }

  func prepare() async throws {
    let permit = AudioPreparationScope.permit
    while true {
      try AudioSessionQueue.checkCancellation()
      do {
        try await complete { binding.prepare(check: {
          do { try permit?.check(); return nil }
          catch { return error as NSError }
        }, configuration: {
          do { try AudioSessionConfiguration.applyOnAudioQueue(permit: permit); return nil }
          catch { return error as NSError }
        }, completion: $0) }
        return
      } catch {
        let failure = error as NSError
        guard ExpoMediaSelection.name == "livekit", failure.domain == "VoIPSDK.MediaAdapter", failure.code == 1 else { throw error }
        // Registry acquisition never blocks the audio queue. The real action's
        // preparation permit/deadline bounds this readiness wait.
        try await Task.sleep(for: .milliseconds(50))
      }
    }
  }
  func didActivate(_ audioSession: AVAudioSession) async throws {
    try await complete { binding.activate(audioSession, completion: $0) }
  }
  func didDeactivate(_ audioSession: AVAudioSession) async throws {
    try await complete { binding.deactivate(audioSession, completion: $0) }
  }
  private func complete(_ operation: (@escaping @Sendable (Error?) -> Void) -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      operation { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
  }
}
