import Foundation
import Testing
import VoIPMediaTesting
import VoIPTesting

@Suite("Measured media teardown")
struct TeardownEvidenceTests {
  @Test func delayedRecordersShareTheAcknowledgedOriginAndIdentity() throws {
    let clock = TestClock()
    let shared = MediaObservationClock(clock: clock)
    clock.advance(by: .milliseconds(1250))
    let first = MediaTeardownEvidence(observationClock: shared)
    first.begin()
    clock.advance(by: .milliseconds(250))
    let second = MediaTeardownEvidence(observationClock: shared)
    second.begin()
    first.record(.engineStopped)
    #expect(first.receipt()?.clockID == shared.id)
    #expect(second.receipt()?.clockID == shared.id)
    #expect(first.receipt()?.startedAtMs == 1250)
    #expect(second.receipt()?.startedAtMs == 1500)
    #expect(first.receipt()?.observations.first?.atMs == shared.seconds * 1000)
  }

  @Test func missingEventsStayIncompleteAndDuplicatesRetainFirstObservation() throws {
    let clock = TestClock()
    let evidence = MediaTeardownEvidence(clock: clock)
    evidence.record(.tapUninstalled)
    #expect(evidence.receipt() == nil)
    evidence.begin()
    for event in MediaTeardownEvidence.Event.allCases.dropLast() {
      clock.advance(by: .milliseconds(20))
      evidence.record(event)
      #expect(evidence.receipt()?.complete == false)
    }
    let partial = try #require(evidence.receipt())
    clock.advance(by: .milliseconds(20))
    evidence.record(.tapUninstalled)
    #expect(evidence.receipt()?.observations.first?.atMs == partial.observations.first?.atMs)
    evidence.record(.audioSessionReleased)
    let final = try #require(evidence.receipt())
    #expect(final.complete)
    #expect(!partial.complete)
    #expect(final.observations.count == 4)
    #expect(
      final.observations.allSatisfy {
        $0.atMs >= final.startedAtMs && $0.atMs <= final.observedAtMs
      })
    let decoded = try JSONDecoder().decode(
      MediaTeardownEvidence.Receipt.self, from: JSONEncoder().encode(final))
    #expect(decoded.complete)
    #expect(decoded.clockID == final.clockID)
  }
  @Test func aNewAttemptCannotReuseOldReleaseEvidence() throws {
    let clock = TestClock()
    let evidence = MediaTeardownEvidence(clock: clock)
    evidence.begin()
    for event in MediaTeardownEvidence.Event.allCases { evidence.record(event) }
    let first = try #require(evidence.receipt())
    #expect(first.complete)
    clock.advance(by: .seconds(1))
    evidence.begin()
    let next = try #require(evidence.receipt())
    #expect(!next.complete)
    #expect(next.observations.isEmpty)
    #expect(next.startedAtMs == first.startedAtMs + 1000)
    #expect(next.clockID == first.clockID)
    let other = MediaTeardownEvidence()
    other.begin()
    #expect(next.clockID != other.receipt()?.clockID)
  }
}
