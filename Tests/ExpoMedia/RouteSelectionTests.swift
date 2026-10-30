import AVFAudio
import Dispatch
import Foundation
import VoIPPlatform
import RouteMediaInterop

typealias VSSelectedMediaBinding = RouteMediaInterop.VSSelectedMediaBinding
extension VSSelectedMediaBinding {
  func activate(_ session: AVFAudio.AVAudioSession, completion: @escaping @Sendable (Error?) -> Void) {
    VSAudioSessionGetQueue().async { completion(nil) }
  }
  func deactivate(_ session: AVFAudio.AVAudioSession, completion: @escaping @Sendable (Error?) -> Void) {
    VSAudioSessionGetQueue().async { completion(nil) }
  }
}
enum ExpoMediaSelection { static let name = "webrtc" }

@main struct RouteSelectionTests {
  enum Failure: Error { case expectedSetterFailure, expectedCancellation, timedOut }
  @MainActor static func main() async throws {
    let adapter = QueuedMediaAdapter(), owner = SystemAudioSession()
    owner.routeConfigurationAdapter = adapter
    owner.setSystemAudioAuthorization(true)
    let limit = ContinuousClock.now + .seconds(3)
    while owner.routes.snapshot.current?.id.rawValue != "output:receiver" {
      guard ContinuousClock.now < limit else { throw Failure.timedOut }
      try await Task.sleep(for: .milliseconds(1))
    }
    let audio = AVFAudio.AVAudioSession.fixture
    try await owner.selectRoute(.init(rawValue: "speaker"), isActive: true)
    try await owner.selectRoute(.init(rawValue: "input:built-in"), isActive: true)
    precondition(audio.writes == 3, "All actual Core route setters must run under the selected WebRTC lock")
    let reads = audio.reads
    audio.rejectNextSetter()
    do { try await owner.selectRoute(.init(rawValue: "speaker"), isActive: true); throw Failure.expectedSetterFailure }
    catch AVFAudio.AVAudioSession.FixtureError.setterRejected {}
    precondition(audio.reads > reads, "An error must reread observed routes")
    try await owner.selectRoute(.init(rawValue: "output:receiver"), isActive: true)
    precondition(audio.writes == 4, "Current output validation must not mutate the session")

    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let release = DispatchSemaphore(value: 0)
    defer { release.signal(); entered.continuation.finish() }
    VSAudioSessionGetQueue().async {
      entered.continuation.yield(())
      precondition(release.wait(timeout: .now() + 3) == .success)
    }
    for await _ in entered.stream { break }
    let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let selection = Task { @MainActor in
      started.continuation.yield(())
      started.continuation.finish()
      try await owner.selectRoute(.init(rawValue: "speaker"), isActive: true)
    }
    // This actor resumes only after selection suspends on its queued callback.
    for await _ in started.stream { break }
    selection.cancel(); release.signal()
    do { try await selection.value; throw Failure.expectedCancellation }
    catch is CancellationError {}
    let state = await AudioSessionQueue.shared.perform {
      (VSRouteConfigurationLocked(), VSRouteGateMutationCount(), VSRouteLockCount())
    }
    precondition(!state.0 && state.1 == 0 && state.2 >= 5 && audio.writes == 4 && audio.configurations == 0,
      "Routes must release the configuration lock on success/error/cancellation and preserve media gates/category")
    print("passed: actual Core→selected Swift adapter→WebRTC binding route lock, error reread, no-op, queued cancellation and unchanged media gates")
  }
}
