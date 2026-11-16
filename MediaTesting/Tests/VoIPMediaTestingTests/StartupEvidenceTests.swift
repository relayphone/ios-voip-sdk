import Foundation
import Testing
import VoIPMediaTesting
import VoIPTesting

@Suite("Measured media startup")
struct StartupEvidenceTests {
  @Test func partialFailureRetainsOnlyActualStagesOnSharedClock() throws {
    let clock = TestClock()
    let shared = MediaObservationClock(clock: clock)
    clock.advance(by: .seconds(2))
    let evidence = MediaStartupEvidence(observationClock: shared)
    #expect(evidence.receipt().observations.isEmpty)
    evidence.record(.prepareEntered)
    clock.advance(by: .milliseconds(125))
    evidence.record(.roomConnectRequested)
    clock.advance(by: .milliseconds(250))
    evidence.record(.roomConnectFailed(errorType: "ConnectionError"))
    let partial = evidence.receipt()
    let decoded = try JSONDecoder().decode(
      MediaStartupEvidence.Receipt.self, from: JSONEncoder().encode(partial))
    #expect(decoded.clockID == shared.id)
    #expect(decoded.observations.map(\.atMs) == [2000, 2125, 2375])
    #expect(
      decoded.observations.map(\.event) == [
        .prepareEntered, .roomConnectRequested, .roomConnectFailed(errorType: "ConnectionError"),
      ])
    clock.advance(by: .seconds(1))
    evidence.record(.roomConnectCompleted)
    evidence.record(.prepareEntered)
    #expect(evidence.receipt().observations.map(\.event) == partial.observations.map(\.event))
    #expect(evidence.receipt().observations.map(\.atMs) == partial.observations.map(\.atMs))
  }

  @Test func firstOccurrencesAreBoundedAndSnapshotsStayIndependent() {
    let evidence = MediaStartupEvidence(observationClock: MediaObservationClock())
    let events: [MediaStartupEvidence.Event] = [
      .prepareEntered, .roomConnectRequested, .roomConnectCompleted, .captureOptionsApplied,
      .prepareCompleted, .activationEntered, .activationEnqueued(.enqueued),
      .activationHandlerEntered,
      .engineAvailabilityObserved(.running), .tapInstalled(.decoded), .tapInstalled(.output),
      .firstCallback(.decoded), .firstCallback(.output),
    ]
    for _ in 0..<1000 { for event in events { evidence.record(event) } }
    let first = evidence.receipt()
    evidence.record(.engineAvailabilityObserved(.unavailable))
    evidence.record(.roomConnectFailed(errorType: "LaterFailure"))
    #expect(first.observations.count == 13)
    #expect(first.observations.map(\.event) == events)
    #expect(evidence.receipt().observations.map(\.event) == events)
  }

  @Test func activationBoundariesAndLatestSDKEventsKeepTheirSharedClock() throws {
    let clock = TestClock()
    let shared = MediaObservationClock(clock: clock)
    let evidence = MediaStartupEvidence(observationClock: shared)
    evidence.record(.prepareCompleted)
    clock.advance(by: .milliseconds(10))
    evidence.record(.activationEntered)
    clock.advance(by: .milliseconds(10))
    evidence.record(.activationEnqueued(.enqueued))
    clock.advance(by: .milliseconds(10))
    evidence.recordAudioEvent(.activated)
    let unconsumed = evidence.receipt()
    #expect(unconsumed.clockID == shared.id)
    #expect(unconsumed.observations.map(\.atMs) == [0, 10, 20])
    #expect(unconsumed.lastAudioActivatedAtMs == 30)
    #expect(unconsumed.lastAudioDeactivatedAtMs == nil)
    clock.advance(by: .milliseconds(10))
    evidence.record(.activationHandlerEntered)
    evidence.record(.engineAvailabilityObserved(.unavailable))
    evidence.recordAudioEvent(.deactivated)
    clock.advance(by: .milliseconds(10))
    evidence.recordAudioEvent(.activated)
    evidence.record(.activationEntered)
    evidence.record(.activationEnqueued(.terminated))
    let decoded = try JSONDecoder().decode(
      MediaStartupEvidence.Receipt.self, from: JSONEncoder().encode(evidence.receipt()))
    #expect(decoded.observations.count == 5)
    #expect(decoded.observations.map(\.atMs) == [0, 10, 20, 40, 40])
    #expect(decoded.lastAudioActivatedAtMs == 50)
    #expect(decoded.lastAudioDeactivatedAtMs == 40)
    #expect(unconsumed.observations.count == 3)
    #expect(unconsumed.lastAudioActivatedAtMs == 30)
  }

  @Test(arguments: [MediaStartupEvidence.Enqueue.dropped, .terminated])
  func enqueueOutcomeNeverBecomesInferredConsumption(_ result: MediaStartupEvidence.Enqueue) {
    let evidence = MediaStartupEvidence(observationClock: MediaObservationClock())
    evidence.record(.activationEntered)
    evidence.record(.activationEnqueued(result))
    #expect(
      evidence.receipt().observations.map(\.event) == [
        .activationEntered, .activationEnqueued(result),
      ])
  }

  @Test func unavailableEngineIsAnActualFirstObservation() {
    let evidence = MediaStartupEvidence(observationClock: MediaObservationClock())
    evidence.record(.engineAvailabilityObserved(.unavailable))
    let partial = evidence.receipt()
    evidence.record(.tapInstalled(.output))
    #expect(partial.observations.map(\.event) == [.engineAvailabilityObserved(.unavailable)])
    #expect(evidence.receipt().observations.count == 2)
  }
}
