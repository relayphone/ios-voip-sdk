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
    // The v0 driver cannot decode v1 steps. Read their headers to validate catalog IDs.
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
    for (id, file) in zip(v0IDs, files) {
      let journey = try JSONDecoder().decode(SpecJourney.self, from: Data(contentsOf: file))
      try #require(journey.id.rawValue == id, "Journey ID must match its filename")
      let differences = try await SpecJourneyDriver.run(journey)
      let details = "\(id)\n\(differences.joined(separator: "\n"))"
      #expect(differences.isEmpty, Comment(rawValue: details))
    }
  }
}
