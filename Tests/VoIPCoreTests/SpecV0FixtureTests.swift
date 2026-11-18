import Foundation
import Testing
import VoIPCore

@Suite struct SpecV0FixtureTests {
  private static let fixtures = URL(filePath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appending(path: "spec/fixtures")

  private static func fixtureURLs(in category: String) -> [URL] {
    do {
      return try FileManager.default.contentsOfDirectory(
        at: fixtures.appending(path: category), includingPropertiesForKeys: nil
      ).filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    } catch {
      preconditionFailure("Cannot enumerate the shared \(category) fixtures: \(error)")
    }
  }

  @Test(arguments: fixtureURLs(in: "valid"))
  func validFixtureRoundTrips(_ url: URL) throws {
    let original = try Data(contentsOf: url)
    let document = try JSONDecoder().decode(SpecV0.Document.self, from: original)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let canonical = try encoder.encode(JSONDecoder().decode(JSONValue.self, from: original))
    #expect(try encoder.encode(document) == canonical)
  }

  @Test(arguments: fixtureURLs(in: "invalid"))
  func invalidFixtureFailsDecoding(_ url: URL) throws {
    let data = try Data(contentsOf: url)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(SpecV0.Document.self, from: data)
    }
  }

  @Test func sharedFixtureCategoriesContainTests() {
    #expect(!Self.fixtureURLs(in: "valid").isEmpty)
    #expect(!Self.fixtureURLs(in: "invalid").isEmpty)
  }

  @Test func wireIdentityPreservesUnicodeBytes() throws {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    let composed = try encoder.encode("é")
    let decomposed = try encoder.encode("e\u{301}")
    let first = try decoder.decode(SpecV0.ID.self, from: composed)
    let second = try decoder.decode(SpecV0.ID.self, from: decomposed)
    #expect(first != second)
    #expect(try encoder.encode(first) == composed)
    #expect(try encoder.encode(second) == decomposed)
  }

  @Test func emailSeparatorsAreUnicodeScalars() throws {
    let decoder = JSONDecoder()
    let valid = Data(#"{"kind":"email","address":"a@\u0301b"}"#.utf8)
    let decoded = try decoder.decode(SpecV0.Handle.self, from: valid)
    guard case .email(let address) = decoded else {
      Issue.record("Expected an email handle")
      return
    }
    #expect(address.utf8.elementsEqual("a@\u{301}b".utf8))

    let invalid = Data(#"{"kind":"email","address":"a@\u0301b@c"}"#.utf8)
    #expect(throws: DecodingError.self) {
      try decoder.decode(SpecV0.Handle.self, from: invalid)
    }
  }

  @Test(arguments: [
    "2026-02-30T00:00:00.000Z",
    "2026-02-28T00:00:00x000Z",
    "2026-02-28T00:00:00.00Z",
    "2026-02-28T00:00:00.000+00:00",
  ])
  func invalidTimestampFails(_ timestamp: String) {
    let data = Data(#"{"kind":"connected","connectedAt":"\#(timestamp)"}"#.utf8)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(SpecV0.Lifecycle.self, from: data)
    }
  }

  @Test func answerBudgetRequiresPreparationRemainder() {
    let data = Data(
      #"{"total":3500,"claim":2500,"reconciliation":500,"settlementReserve":500}"#.utf8)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(SpecV0.Budgets.Answer.self, from: data)
    }
  }

  @Test(arguments: [
    #"{"lifetime":0,"terminalRecords":42}"#,
    #"{"lifetime":7500,"terminalRecords":0}"#,
    #"{"lifetime":7500,"terminalRecords":2147483648}"#,
    #"{"lifetime":7500,"terminalRecords":42,"other":true}"#,
    #"{"lifetime":7500}"#,
  ])
  func malformedRetentionBudgetFails(_ value: String) {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(SpecV0.Budgets.Retention.self, from: Data(value.utf8))
    }
  }

  @Test func invalidConfigurationCanIdentifyRetention() throws {
    let data = Data(#"{"kind":"invalidConfiguration","field":"retention"}"#.utf8)
    let failure = try JSONDecoder().decode(SpecV0.Failure.self, from: data)
    guard case .invalidConfiguration(.retention) = failure else {
      Issue.record("Expected an invalid retention configuration")
      return
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    #expect(
      try encoder.encode(failure)
        == Data(#"{"field":"retention","kind":"invalidConfiguration"}"#.utf8))
  }
}
