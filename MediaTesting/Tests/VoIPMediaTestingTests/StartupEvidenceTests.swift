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
      .engineAvailabilityObserved(.running), .tapInstalled(.decoded), .tapInstalled(.output),
      .firstCallback(.decoded), .firstCallback(.output),
    ]
    for _ in 0..<1000 { for event in events { evidence.record(event) } }
    let first = evidence.receipt()
    evidence.record(.engineAvailabilityObserved(.unavailable))
    evidence.record(.roomConnectFailed(errorType: "LaterFailure"))
    #expect(first.observations.count == 9)
    #expect(first.observations.map(\.event) == events)
    #expect(evidence.receipt().observations.map(\.event) == events)
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
