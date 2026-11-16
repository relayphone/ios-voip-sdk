import CKSimProtocol
import Foundation
import Testing

struct ProcessLifecycleProtocolTests {
  @Test(arguments: ["", "../other", "a/b", "a b"])
  func invalidInvocationNamesCannotNameSegments(run: String) {
    #expect(throws: (any Error).self) {
      try ProcessLifecycleIdentity(simulatorID: UUID(), bundleID: "dev.example", runID: run)
    }
  }

  @Test func recordsRoundTripWithUnknownExitCauseAndNoFabricatedProcess() throws {
    let identity = try ProcessLifecycleIdentity(
      simulatorID: UUID(), bundleID: "dev.example", runID: "cold-run")
    let row = try ProcessLifecycleRecord(
      identity: identity, producerID: UUID(), sequence: 1, event: .launchRequested,
      uptimeNanoseconds: 123, wallTimeMS: 456, cause: .unknown)
    let bytes = try JSONEncoder().encode(row)
    #expect(try JSONDecoder().decode(ProcessLifecycleRecord.self, from: bytes) == row)
    #expect(row.pid == nil)
    let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    for (key, value) in [
      ("schemaVersion", 2), ("sequence", 0), ("uptimeNanoseconds", 0), ("wallTimeMS", -1),
      ("pid", 0),
    ] {
      var invalid = object
      invalid[key] = value
      let data = try JSONSerialization.data(withJSONObject: invalid)
      #expect(throws: (any Error).self) {
        try JSONDecoder().decode(ProcessLifecycleRecord.self, from: data)
      }
    }
  }

  @Test func newerEventNamesRemainReadable() throws {
    let event = try JSONDecoder().decode(
      ProcessLifecycleEvent.self, from: Data(#""process.futureBoundary""#.utf8))
    #expect(event.rawValue == "process.futureBoundary")
    #expect(try JSONEncoder().encode(event) == Data(#""process.futureBoundary""#.utf8))
  }
}
