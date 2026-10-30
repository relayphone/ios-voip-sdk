import CKSimProtocol
import Foundation
import Testing

struct RuntimeSessionTests {
  private static let wire =
    #"{"schemaVersion":1,"bundleID":"dev.callkitsim.fixture","runID":"run_ABC-123","pid":123,"profile":"ios-27.0","controlTransport":"directory-watch-v1"}"#

  @Test func existingSessionRoundTripsWithoutChangingFieldTypes() throws {
    let bytes = Data(Self.wire.utf8)
    let session = try JSONDecoder().decode(RuntimeSession.self, from: bytes)
    #expect(session.schemaVersion == 1)
    #expect(session.runID == "run_ABC-123")
    #expect(session.bundleID == "dev.callkitsim.fixture")
    #expect(session.pid == 123)
    #expect(session.profile == "ios-27.0")
    #expect(session.controlTransport == .directoryWatchV1)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let encoded = try encoder.encode(session)
    #expect(
      String(decoding: encoded, as: UTF8.self)
        == #"{"bundleID":"dev.callkitsim.fixture","controlTransport":"directory-watch-v1","pid":123,"profile":"ios-27.0","runID":"run_ABC-123","schemaVersion":1}"#
    )
    #expect(try JSONDecoder().decode(RuntimeSession.self, from: encoded) == session)
  }

  @Test(arguments: [
    ("\"schemaVersion\":1", "\"schemaVersion\":2"),
    ("\"schemaVersion\":1", "\"schemaVersion\":true"),
    ("\"pid\":123", "\"pid\":0"),
    ("\"pid\":123", "\"pid\":-1"),
    ("\"pid\":123", "\"pid\":true"),
    ("\"pid\":123", "\"pid\":\"123\""),
    ("dev.callkitsim.fixture", ""),
    ("ios-27.0", ""),
    ("run_ABC-123", ""),
    ("run_ABC-123", "../outside"),
    ("run_ABC-123", "run/child"),
    ("run_ABC-123", "run\\n"),
    ("run_ABC-123", "é"),
    ("run_ABC-123", String(repeating: "a", count: 65)),
    ("directory-watch-v1", "notify-v1"),
    (",\"controlTransport\":\"directory-watch-v1\"", ""),
  ])
  func malformedIdentityCannotBecomeAnInspectorSession(replacement: (String, String)) {
    let wire = Self.wire.replacingOccurrences(of: replacement.0, with: replacement.1)
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(RuntimeSession.self, from: Data(wire.utf8))
    }
  }

  @Test func additiveMetadataDoesNotChangeSessionIdentity() throws {
    let original = try JSONDecoder().decode(RuntimeSession.self, from: Data(Self.wire.utf8))
    let additive = Self.wire.dropLast() + #", "futureMetadata": {"supported":true}}"#
    #expect(try JSONDecoder().decode(RuntimeSession.self, from: Data(additive.utf8)) == original)
  }

  @Test(arguments: [
    (#""schemaVersion":1,"#, #""schemaVersion":null,"#),
    (#""bundleID":"dev.callkitsim.fixture","#, #""bundleID":null,"#),
    (#""runID":"run_ABC-123","#, #""runID":null,"#),
    (#""pid":123,"#, #""pid":null,"#),
    (#""profile":"ios-27.0","#, #""profile":null,"#),
    (",\"controlTransport\":\"directory-watch-v1\"", ",\"controlTransport\":null"),
  ])
  func everyIdentityFieldMustBePresentAndNonNull(field: (String, String)) {
    for replacement in ["", field.1] {
      let wire = Self.wire.replacingOccurrences(of: field.0, with: replacement)
      #expect(throws: (any Error).self) {
        try JSONDecoder().decode(RuntimeSession.self, from: Data(wire.utf8))
      }
    }
  }

  @Test(arguments: ["x", String(repeating: "a", count: 64)])
  func runIdentifierLengthBoundariesRemainSupported(runID: String) throws {
    let session = try RuntimeSession(bundleID: "fixture", runID: runID, pid: 1, profile: "ios-27.0")
    #expect(
      try JSONDecoder().decode(RuntimeSession.self, from: JSONEncoder().encode(session)) == session)
  }

  @Test func producerAndConsumerUseTheSameIdentity() throws {
    let published = try RuntimeSession(
      bundleID: "dev.callkitsim.fixture", runID: "run_ABC-123", pid: 123, profile: "ios-27.0"
    )
    #expect(try JSONDecoder().decode(RuntimeSession.self, from: Data(Self.wire.utf8)) == published)
    #expect(throws: RuntimeSession.ValidationError.invalidRunID) {
      try RuntimeSession(bundleID: "fixture", runID: "run\n", pid: 1, profile: "ios-27.0")
    }
    let replacement = try RuntimeSession(
      bundleID: "dev.callkitsim.fixture", runID: "another-run", pid: 123, profile: "ios-27.0"
    )
    #expect(published != replacement)
    // Replacing any bound identity must invalidate an Inspector's pinned session.
    for changed in [
      try RuntimeSession(
        bundleID: "another.bundle", runID: published.runID, pid: 123, profile: published.profile),
      try RuntimeSession(
        bundleID: published.bundleID, runID: published.runID, pid: 456, profile: published.profile),
      try RuntimeSession(
        bundleID: published.bundleID, runID: published.runID, pid: 123, profile: "another-profile"),
    ] {
      #expect(published != changed)
    }
  }
}
