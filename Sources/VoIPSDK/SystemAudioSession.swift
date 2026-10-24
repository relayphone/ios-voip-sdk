#if canImport(AVFAudio) && (os(iOS) || os(watchOS))
import Foundation
import AVFAudio
import os
#if canImport(VoIPPlatform)
import VoIPPlatform
#endif


enum SystemAudioLifecycleEvent: Sendable, Equatable {
  case active
  case inactive(source: Int?, interruptionReason: UInt?)
  case resumptionRecommended(Bool)
  case mediaServicesReset
}

#if DEBUG && targetEnvironment(simulator)
@MainActor
enum AudioLifecycleDiagnostics {
  /// Internal scalar-only acceptance observation, compiled out of device and Release builds.
  static var didConsume: (@MainActor (SystemAudioLifecycleEvent, Bool, Bool) -> Void)?
}
#endif

@MainActor
final class SystemAudioSession {
  var onLifecycle: (@MainActor (SystemAudioLifecycleEvent) -> Void)?
  private var lifecycleObserver: VSAudioSessionLifecycleObserver?
  private let authorization = OSAllocatedUnfairLock(initialState: false)

  init() {
    lifecycleObserver = VSAudioSessionLifecycleObserver { [weak self] value in
      let event: SystemAudioLifecycleEvent
      switch value.kind {
      case .active: event = .active
      case .inactive:
        event = .inactive(source: value.hasSource ? value.source : nil,
          interruptionReason: value.hasInterruptionReason ? value.interruptionReason : nil)
      case .resumptionRecommended: event = .resumptionRecommended(value.shouldResume)
      case .mediaServicesReset: event = .mediaServicesReset
      @unknown default: return
      }
      MainActor.assumeIsolated { self?.deliver(event) }
    }
  }

  /// Resumption is advisory: it never activates a session or authorizes an engine.
  private func deliver(_ event: SystemAudioLifecycleEvent) {
    #if DEBUG && targetEnvironment(simulator)
    let authorizedBefore = authorization.withLock { $0 }
    #endif
    switch event {
    case .inactive, .mediaServicesReset: authorization.withLock { $0 = false }
    case .active, .resumptionRecommended: break
    }
    onLifecycle?(event)
    #if DEBUG && targetEnvironment(simulator)
    AudioLifecycleDiagnostics.didConsume?(event, authorizedBefore, authorization.withLock { $0 })
    #endif
  }

  func setSystemAudioAuthorization(_ active: Bool) { authorization.withLock { $0 = active } }
}
#endif
