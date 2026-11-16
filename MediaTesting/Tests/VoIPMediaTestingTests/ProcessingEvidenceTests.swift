import Foundation
import Testing
import VoIPMediaTesting

@Suite("Effective capture processing")
struct ProcessingEvidenceTests {
  private let expected = MediaProcessingEvidence.Configuration(aec: false, ns: false, agc: true)

  @Test func unavailableRequestsWithMatchingActiveStatePass() throws {
    let evidence = MediaProcessingEvidence(
      expected: expected, applied: expected, active: expected,
      engineRunning: true, requested: [:])
    #expect(evidence.passed)
    #expect(evidence.requestedUnobserved == [.aec, .ns, .agc])
    struct Receipt: Decodable {
      let requestedUnobserved: [String]
      let requested: [String: Bool]
    }
    let receipt = try JSONDecoder().decode(Receipt.self, from: JSONEncoder().encode(evidence))
    #expect(receipt.requestedUnobserved == ["aec", "ns", "agc"])
    #expect(receipt.requested.isEmpty)
  }

  @Test func matchingObservedRequestsPass() {
    let evidence = MediaProcessingEvidence(
      expected: expected, applied: expected, active: expected,
      engineRunning: true, requested: [.aec: false, .agc: true])
    #expect(evidence.passed)
    #expect(evidence.requestedUnobserved == [.ns])
  }

  @Test(arguments: MediaProcessingEvidence.Effect.allCases)
  func mismatchedObservedRequestFails(effect: MediaProcessingEvidence.Effect) {
    let evidence = MediaProcessingEvidence(
      expected: expected, applied: expected, active: expected,
      engineRunning: true, requested: [effect: effect != .agc])
    #expect(!evidence.passed)
  }

  @Test(arguments: [
    MediaProcessingEvidence.Configuration(aec: true, ns: false, agc: true),
    .init(aec: false, ns: true, agc: true), .init(aec: false, ns: false, agc: false),
  ])
  func mismatchedActiveStateFails(active: MediaProcessingEvidence.Configuration) {
    #expect(
      !MediaProcessingEvidence(
        expected: expected, applied: expected, active: active,
        engineRunning: true, requested: [:]
      ).passed)
  }

  @Test(arguments: [
    MediaProcessingEvidence.Configuration(aec: true, ns: false, agc: true),
    .init(aec: false, ns: true, agc: true), .init(aec: false, ns: false, agc: false), nil,
  ])
  func mismatchedOrMissingAdapterOptionsFail(applied: MediaProcessingEvidence.Configuration?) {
    #expect(
      !MediaProcessingEvidence(
        expected: expected, applied: applied, active: expected,
        engineRunning: true, requested: [:]
      ).passed)
  }

  @Test func stoppedEngineFails() {
    #expect(
      !MediaProcessingEvidence(
        expected: expected, applied: expected, active: expected,
        engineRunning: false, requested: [:]
      ).passed)
  }
}
