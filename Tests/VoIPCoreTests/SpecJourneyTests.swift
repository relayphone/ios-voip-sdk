import Foundation
import Testing
import VoIPCore
import VoIPTesting

private let catalog = URL(filePath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .appending(path: "spec/journeys", directoryHint: .isDirectory)

private let pending: [String: String] = [
  "answer-not-allowed": "No native claim port or typed notAllowed refusal.",
  "answer-refusal": "No native claim port to end the call with the refusal's ownership reason.",
  "answer-refusal-preview": "No native claim port to apply preview policy to an ownership refusal.",
  "claim-timeout-reconcile": "No native claim budget or reconciliation port.",
  "cross-line-waiting":
    "No line identity or shared participation slot to refuse a second Answer or Start.",
  "end-after-server-end": "End rejects a server-ended call instead of returning alreadyEnded.",
  "end-before-admission": "Alias-addressed ends cannot reach a call during pending admission.",
  "incoming-killed-answer": "Native Answer prepares media without a service claim.",
  "late-answer-permit": "No native claim deadline, reconciliation, or stale permit release.",
  "local-server-end-race":
    "Repeated local End rejects an already ended call instead of returning its receipt.",
  "no-answer-direction": "The system end port reports one unanswered cause for both directions.",
  "outgoing-deferred-binding": "Remote alias binding and alias-addressed events are missing.",
]

@Suite(.timeLimit(.minutes(1)))
struct SpecJourneyTests {
  @Test func sharedJourneys() async throws {
    let files = try FileManager.default.contentsOfDirectory(
      at: catalog, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    try #require(!files.isEmpty)
    let journeys = try files.map {
      try JSONDecoder().decode(SpecJourney.self, from: Data(contentsOf: $0))
    }
    let ids = journeys.map(\.id.rawValue)
    try #require(Set(journeys.map(\.id)).count == journeys.count, "Duplicate journey IDs")
    #expect(Set(pending.keys).isSubset(of: Set(ids)), "Unknown pending journey IDs")
    for journey in journeys {
      let differences = try await SpecJourneyDriver.run(journey)
      let id = journey.id.rawValue
      let details = "\(id)\n\(differences.joined(separator: "\n"))"
      if let reason = pending[id] {
        withKnownIssue(Comment(rawValue: "\(id) — \(reason)")) {
          #expect(differences.isEmpty, Comment(rawValue: details))
        }
      } else {
        #expect(differences.isEmpty, Comment(rawValue: details))
      }
    }
  }
}
