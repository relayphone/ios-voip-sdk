import Foundation
import Testing
import VoIPCore
import VoIPTesting

private let catalog = URL(filePath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .appending(path: "spec/journeys", directoryHint: .isDirectory)
private let v1Catalog = catalog.deletingLastPathComponent()
  .appending(path: "v1/journeys", directoryHint: .isDirectory)

private struct JourneyHeader: Decodable {
  let id: String
  let version: Int
}

private let pending: [String: String] = [
  "answer-not-allowed": "No native claim port or typed notAllowed refusal.",
  "answer-refusal": "No native claim port to end the call with the refusal's ownership reason.",
  "answer-refusal-preview": "No native claim port to apply preview policy to an ownership refusal.",
  "claim-timeout-reconcile": "No native claim budget or reconciliation port.",
  "cross-line-waiting":
    "No line identity or shared participation slot to refuse a second Answer or Start.",
  "end-before-admission": "Alias-addressed ends cannot reach a call during pending admission.",
  "http-answer-allow": "No native HTTP claim transport or permit handling.",
  "http-answer-late-permit-release": "No native HTTP compensation for a stale permit.",
  "http-answer-refused-elsewhere": "No native HTTP refusal mapping.",
  "http-answer-timeout-reconcile": "No native HTTP deadline and reconciliation handling.",
  "incoming-killed-answer": "Native Answer prepares media without a service claim.",
  "late-answer-permit": "No native claim deadline, reconciliation, or stale permit release.",
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
    let v0IDs = files.map { $0.deletingPathExtension().lastPathComponent }
    // The v0 driver cannot decode v1 steps. Read their headers for pending-list validation.
    let v1IDs = try FileManager.default.contentsOfDirectory(
      at: v1Catalog, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" }
    .map { file in
      let header = try JSONDecoder().decode(JourneyHeader.self, from: Data(contentsOf: file))
      #expect(header.version == 1)
      #expect(header.id == file.deletingPathExtension().lastPathComponent)
      return header.id
    }
    let ids = v0IDs + v1IDs
    try #require(Set(ids).count == ids.count, "Duplicate journey IDs")
    #expect(Set(pending.keys).isSubset(of: Set(ids)), "Unknown pending journey IDs")
    for (id, file) in zip(v0IDs, files) {
      let journey = try JSONDecoder().decode(SpecJourney.self, from: Data(contentsOf: file))
      try #require(journey.id.rawValue == id, "Journey ID must match its filename")
      let differences = try await SpecJourneyDriver.run(journey)
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
