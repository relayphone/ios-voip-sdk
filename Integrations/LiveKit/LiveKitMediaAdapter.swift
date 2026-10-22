#if os(iOS)
import AVFAudio
import LiveKit
import VoIPSDK
import os

/// Optional source integration for an app that already uses the LiveKit Swift SDK.
/// Add this file to the app target; it is deliberately outside the dependency-free package.
@MainActor
public final class LiveKitMediaAdapter: MediaAdapter {
  private let authorization = OSAllocatedUnfairLock(initialState: false)
  private let worker: Worker
  public init() { worker = Worker(authorization: authorization) }
  public func setSystemAudioAuthorization(_ active: Bool) { authorization.withLock { $0 = active } }
  public func prepare() async throws { try await worker.prepare() }
  public func didActivate(_ audioSession: AVAudioSession) async throws { try await worker.setAvailable(true) }
  public func didDeactivate(_ audioSession: AVAudioSession) async throws { try await worker.setAvailable(false) }

  /// Only value arguments cross actors. The backend singleton is resolved and used here;
  /// its synchronous operations cannot block MainActor or require a Sendable assertion.
  private actor Worker {
    let authorization: OSAllocatedUnfairLock<Bool>
    init(authorization: OSAllocatedUnfairLock<Bool>) { self.authorization = authorization }
    func prepare() throws {
      AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
      try AudioManager.shared.setEngineAvailability(.none)
    }
    func setAvailable(_ active: Bool) throws {
      let allowed = active && authorization.withLock { $0 }
      try AudioManager.shared.setEngineAvailability(allowed ? .default : .none)
    }
  }
}
#endif
