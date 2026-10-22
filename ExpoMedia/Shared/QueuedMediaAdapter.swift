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
    try await complete { binding.prepare(completion: $0) }
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
