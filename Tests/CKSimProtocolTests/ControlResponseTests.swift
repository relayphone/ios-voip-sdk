import Foundation
import Testing

@testable import CKSimProtocol

@Suite struct ControlResponseTests {
  private static let id = "11111111-1111-4111-8111-111111111111"
  private static let action = "22222222-2222-4222-8222-222222222222"
  private static let transaction = "33333333-3333-4333-8333-333333333333"
  private static let filter = #"{"reason":"none","code":0,"verification":"not-applicable"}"#
  private static let call = #"""
    "uuid":"11111111-1111-4111-8111-111111111111","outgoing":false,"connected":true,
    "held":false,"ended":false,"muted":false,"ringing":false,"callerName":"Caller",
    "handle":"handle","capabilities":["pausing","merging","unmerging"]
    """#
  private static var status: String {
    #"{"calls":[{"apiKind":"callkit","group":"\#(id)",\#(call)}],"pending":1,"audioActive":true,"sequence":42,"incomingErrorCode":0,"incomingFilter":\#(filter),"providerConfigurations":[{"provider":"ObjectIdentifier(0x1234)","apiKind":"callkit","selected":true,"valid":true,"maximumCallGroups":2,"maximumCallsPerCallGroup":1}]}"#
  }
  private static var results: [String] {
    [
      status, #"{"events":"line\n"}"#, #"{"metadataSelector":false}"#,
      #"{"incomingFilter":\#(filter)}"#, #"{"configured":true,"incomingErrorCode":4}"#,
      #"{"scheduled":true,"pushID":"\#(id)"}"#,
      #"{"reset":true,"provider":"ObjectIdentifier(0x1234)"}"#,
      #"{"actionIDs":["\#(action)"],"transactionID":"\#(transaction)"}"#,
    ]
  }
  private func envelope(_ body: String) -> Data {
    Data(#"{"id":"\#(Self.id)","runID":"run_1","pid":123,"bundleID":"example.app",\#(body)}"#.utf8)
  }

  @Test(arguments: results)
  func everyExistingResultRetainsItsFlatWire(_ result: String) throws {
    let bytes = envelope(#""success":true,"result":\#(result)"#)
    let response = try JSONDecoder().decode(ControlResponse.self, from: bytes)
    #expect(response.id == UUID(uuidString: Self.id))
    #expect(
      response.target == (try RuntimeIdentity(bundleID: "example.app", runID: "run_1", pid: 123)))
    guard case .success = response.outcome else {
      Issue.record("Expected success")
      return
    }
    let encoded = try JSONEncoder().encode(response)
    #expect(
      (try JSONSerialization.jsonObject(with: bytes) as? NSDictionary)
        == (try JSONSerialization.jsonObject(with: encoded) as? NSDictionary))
    #expect(try JSONDecoder().decode(ControlResponse.self, from: encoded) == response)
  }

  @Test func legacyFailureMessageRemainsUnchanged() throws {
    let bytes = envelope(#""success":false,"error":"invalid(\"unknown call or provider\")""#)
    let response = try JSONDecoder().decode(ControlResponse.self, from: bytes)
    #expect(
      response.outcome == .failure(ControlFailure(message: #"invalid("unknown call or provider")"#))
    )
    #expect(
      (try JSONSerialization.jsonObject(with: bytes) as? NSDictionary)
        == (try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? NSDictionary)
    )
  }

  @Test func lckChoicesDoNotBecomeCallKitGroups() throws {
    let result = Self.status.replacingOccurrences(
      of: #""apiKind":"callkit","group":"\#(Self.id)""#,
      with:
        #""apiKind":"livecommunicationkit","availableSystemChoices":["end-and-accept","decline"]"#)
    let response = try JSONDecoder().decode(
      ControlResponse.self,
      from: envelope(#""success":true,"result":\#(result)"#))
    guard case .success(.status(let snapshot)) = response.outcome else {
      Issue.record("Expected status")
      return
    }
    #expect(
      snapshot.calls.first?.relationship
        == .livecommunicationkit(availableSystemChoices: [.endAndAccept, .decline]))
    #expect(snapshot.providerConfigurations.first?.provider == "ObjectIdentifier(0x1234)")
  }

  @Test(arguments: [
    #""success":true,"error":"failure","result":{"events":""}"#,
    #""success":false,"error":"failure","result":null"#,
    #""success":false"#, #""success":true"#,
    #""success":"true","result":{"events":""}"#,
    #""success":1,"result":{"events":""}"#,
  ])
  func inconsistentOutcomesReject(_ body: String) {
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(ControlResponse.self, from: envelope(body))
    }
  }

  @Test(arguments: [
    #"{}"#, #"{"events":"","metadataSelector":true}"#,
    #"{"incomingFilter":null}"#,
    #"{"incomingFilter":{"reason":"none","code":3,"verification":"not-applicable"}}"#,
    #"{"incomingFilter":{"reason":"do-not-disturb","code":3,"verification":"unverified"}}"#,
    #"{"configured":false,"incomingErrorCode":0}"#,
    #"{"configured":true,"incomingErrorCode":5}"#,
    #"{"scheduled":false,"pushID":"11111111-1111-4111-8111-111111111111"}"#,
    #"{"reset":true,"provider":42}"#,
    #"{"actionIDs":[],"transactionID":"33333333-3333-4333-8333-333333333333"}"#,
    #"{"actionIDs":["bad-id"],"transactionID":"33333333-3333-4333-8333-333333333333"}"#,
    #"{"actionIDs":["22222222-2222-4222-8222-222222222222","22222222-2222-4222-8222-222222222222"],"transactionID":"33333333-3333-4333-8333-333333333333"}"#,
    #"{"actionIDs":["22222222-2222-4222-8222-222222222222"]}"#,
    #"{"events":"","transactionID":"33333333-3333-4333-8333-333333333333"}"#,
  ])
  func malformedOrAmbiguousResultNeverFallsBack(_ result: String) {
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(
        ControlResponse.self,
        from: envelope(#""success":true,"result":\#(result)"#))
    }
  }

  @Test(arguments: [
    (#""group":"11111111-1111-4111-8111-111111111111""#, #""availableSystemChoices":[]"#),
    (#""apiKind":"callkit""#, #""apiKind":"unknown""#),
    (#""capabilities":["pausing","merging","unmerging"]"#, #""capabilities":["unknown"]"#),
    (#""pending":1"#, #""pending":-1"#),
    (#""sequence":42"#, #""sequence":1.5"#),
    (#""audioActive":true"#, #""audioActive":1"#),
  ])
  func malformedSnapshotsReject(_ replacement: (String, String)) {
    let result = Self.status.replacingOccurrences(of: replacement.0, with: replacement.1)
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(
        ControlResponse.self,
        from: envelope(#""success":true,"result":\#(result)"#))
    }
  }

  @Test func additiveMetadataDoesNotSelectAnotherResult() throws {
    let response = try JSONDecoder().decode(
      ControlResponse.self,
      from: envelope(#""success":true,"result":{"events":"text","extension":42},"extension":true"#))
    #expect(response.outcome == .success(.events("text")))
  }
}
