import Dispatch
import Foundation
import VoIPPlatform
import os

// Explicit inert facades: this test never loads AVFAudio, LiveKit or an app.
final class Observer: Sendable {}
enum ManualEngineObservation { static let shared = Observer() }
enum ColdAudio {
  static let entered = AsyncStream<Void>.makeStream()
  static let release = DispatchSemaphore(value: 0)
}
final class AudioManager: Sendable {
  static let shared = AudioManager()
  let audioSession = Observer(), mixer = Observer()
  private let configured = OSAllocatedUnfairLock(initialState: false)
  private init() {
    precondition(VSAudioSessionIsOnQueue() && !Thread.isMainThread)
    ColdAudio.entered.continuation.yield(())
    precondition(ColdAudio.release.wait(timeout: .now() + 2) == .success, "Cold audio was not released")
  }
  func set(engineObservers: [Observer]) {
    precondition(VSAudioSessionIsOnQueue() && !Thread.isMainThread)
    precondition(engineObservers.count == 3 && engineObservers[0] === audioSession &&
      engineObservers[1] === mixer && engineObservers[2] === ManualEngineObservation.shared,
      "Default audio-session/mixer observer identities and order must be preserved")
    configured.withLock { $0 = true }
  }
  var observersInstalled: Bool { configured.withLock { $0 } }
}
@MainActor final class ObservedAdapter {
  static var created: ObservedAdapter?
  init() { precondition(Self.created == nil); Self.created = self }
}
@MainActor final class VoIPApplication {
  final class Client {}
  let client = Client()
  static var starts = 0
  static var adapter: ObservedAdapter?
  static var policy: AudioActivationPolicy?
  static func start(mediaAdapter: ObservedAdapter, audioPolicy: AudioActivationPolicy) throws -> VoIPApplication {
    starts += 1; adapter = mediaAdapter; policy = audioPolicy
    return VoIPApplication()
  }
}
@MainActor enum Trace {
  static func log(_ event: String, _ fields: [String: Any]) {}
}
@MainActor enum FaultReadiness { static var waits = 0 }
extension NativeJourney {
  // Entry observation only; real ACK validation belongs to native acceptance.
  func waitForFault() async throws { FaultReadiness.waits += 1 }
}
private enum Failure: Error { case assertion(String) }
@main struct StartupTests {
  @MainActor static func main() async throws {
    let mode = CommandLine.arguments[1]
    let journey = Task { try await NativeJourney().journey(mode) }
    defer { ColdAudio.release.signal(); ColdAudio.entered.continuation.finish() }
    for await _ in ColdAudio.entered.stream { break }
    let startsBeforeRelease = VoIPApplication.starts
    let faultWaitsBeforeRelease = FaultReadiness.waits
    ColdAudio.release.signal()
    try await journey.value
    try expect(startsBeforeRelease == 1, "SDK must start before cold audio initialization can block")
    try expect(faultWaitsBeforeRelease == (mode == "stale-audio" ? 1 : 0),
      "Stale fault readiness must precede cold audio initialization; healthy must not wait")
    try expect(VoIPApplication.starts == 1 && VoIPApplication.adapter === ObservedAdapter.created,
      "Startup must retain the selected adapter and create one application")
    let expected = mode == "stale-audio"
      ? try AudioActivationPolicy(activationTimeout: 1, recoveryTimeout: 1) : .standard
    try expect(VoIPApplication.policy == expected, "Startup must retain the selected audio policy")
    try expect(AudioManager.shared.observersInstalled, "Startup must await observer installation")
    print("passed: \(mode); actual probe startup and audio queue with inert facades only")
  }
  private static func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure.assertion(message) }
  }
}
