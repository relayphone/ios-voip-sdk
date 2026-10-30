import Foundation
import Testing

@testable import VoIPSDK

struct PushDecodingTests {
  @Test func nonJSONOptionalAndIgnoredValuesDoNotRejectInvitations() throws {
    var body = invitation
    body["startedAt"] = Date(timeIntervalSince1970: 0)
    body["metadata"] = ["value": Double.nan]
    body["unused"] = Data([1])
    let payload = try #require(PushWire.decodeIncomingInvitation(body))
    #expect(payload.startedAt == nil && payload.metadata == nil)
    #expect(
      PushWire.parse([
        "incomingCall": body, "incoming_call": Date(timeIntervalSince1970: 0), "unused": Data([1]),
      ]) == .incoming(payload))
    #expect(
      PushWire.parse(["incoming_call": body, "unused": Date(timeIntervalSince1970: 0)])
        == .incoming(payload))
    let ended = CallEndedPayload(eventId: "end", serverCallId: "s")
    #expect(
      PushWire.decodeCallEnded(["eventId": "end", "serverCallId": "s", "unused": Data([1])])
        == ended)
    #expect(
      PushWire.parse([
        "messageType": "callEnded", "callEnded": "{\"eventId\":\"end\",\"serverCallId\":\"s\"}",
        "unused": Data([1]),
      ]) == .callEnded(ended))
  }

  @Test func metadataPreservesLargeSignedIntegers() throws {
    for literal in ["9007199254740993", "9223372036854775807", "-9223372036854775808"] {
      let value = try JSONDecoder().decode(JSONValue.self, from: Data(literal.utf8))
      #expect(String(decoding: try JSONEncoder().encode(value), as: UTF8.self) == literal)
    }
  }

  @Test func invitationExposesAnInstant() throws {
    let data = Data(
      #"{"eventId":"e","serverCallId":"s","caller":{"handleType":"generic","value":"caller","displayName":"Caller"},"startedAt":"2026-10-22T00:00:00.125Z","hasVideo":false}"#
        .utf8)
    let payload = try JSONDecoder().decode(IncomingCallPayload.self, from: data)
    #expect(payload.startedAt == Date(timeIntervalSince1970: 1792627200.125))
    #expect(
      try JSONDecoder().decode(IncomingCallPayload.self, from: JSONEncoder().encode(payload))
        == payload)
  }

  @Test func unknownEndReasonsAreRejected() {
    #expect(
      PushWire.decodeCallEnded(["eventId": "e", "serverCallId": "s", "reason": "futureReason"])
        == nil)
  }

  @Test func metadataDistinguishesIntegersFractionsAndBooleans() throws {
    let data = Data(
      #"{"integer":9007199254740993,"fraction":1.25,"flag":true,"nested":[-2,null]}"#.utf8)
    let values = try JSONDecoder().decode([String: JSONValue].self, from: data)
    #expect(
      values == [
        "integer": .int(9_007_199_254_740_993), "fraction": .double(1.25), "flag": .bool(true),
        "nested": .array([.int(-2), .null]),
      ])
    #expect(
      try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(values))
        == values)
    #expect(throws: EncodingError.self) { try JSONEncoder().encode(JSONValue.double(.infinity)) }
  }

  @Test(arguments: [
    "2026-02-30T12:00:00Z", "2026-10-22", "2026-10-22T25:00:00Z", "2026-10-22T00:00:00",
    "2026-10-22T00:00:00+25:00", "2026-10-22T00:00:00+01:99", "2026-10-22T00:00:00Zjunk",
    "2026-10-22T00:00:00.Z", "0000-10-22T00:00:00Z", "2026-10-22T00:00:60Z",
  ])
  func invalidOptionalDatesDoNotRejectAnInvitation(text: String) throws {
    var body = invitation
    body["startedAt"] = text
    let payload = try #require(PushWire.decodeIncomingInvitation(body))
    #expect(payload.startedAt == nil)
  }

  @Test(arguments: [
    "2026-10-22T00:00:00Z", "2026-10-22t00:00:00z", "2026-10-22T02:00:00+02:00",
    "2026-10-21T19:30:00-04:30", "2026-10-22T23:59:00+23:59", "2026-10-21T00:01:00-23:59",
  ])
  func offsetsDescribeTheSameInstant(text: String) throws {
    var body = invitation
    body["startedAt"] = text
    #expect(
      try #require(PushWire.decodeIncomingInvitation(body)).startedAt
        == Date(timeIntervalSince1970: 1_792_627_200))
  }

  @Test func longFractionsRetainTheInstant() throws {
    var body = invitation
    body["startedAt"] = "2026-10-22T00:00:00.1234567890Z"
    let expected = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(
      "2026-10-22T00:00:00.123456789Z")
    #expect(try #require(PushWire.decodeIncomingInvitation(body)).startedAt == expected)
  }

  @Test(arguments: [
    ("2026-10-22T00:00:00.999999999Z", 1_792_627_201.0),
    ("2026-10-22T00:00:00.9999999990Z", 1_792_627_201.0),
    ("2026-10-22T23:59:59.9999999990Z", 1_792_713_600.0),
    ("2026-10-22T23:59:59.9999999990+23:59", 1_792_627_260.0),
  ])
  func fractionsCanRoundAcrossCalendarBoundaries(text: String, seconds: TimeInterval) throws {
    var body = invitation
    body["startedAt"] = text
    #expect(
      try #require(PushWire.decodeIncomingInvitation(body)).startedAt
        == Date(timeIntervalSince1970: seconds))
  }

  @Test func envelopePrecedenceAndRequiredReportingRemainIntact() throws {
    let valid = try #require(PushWire.decodeIncomingInvitation(invitation))
    #expect(PushWire.parse(["incoming_call": invitation]) == .incoming(valid))
    #expect(PushWire.parse(["incomingCall": NSNull(), "incoming_call": invitation]) == .malformed)
    #expect(PushWire.parse(["incomingCall": "invalid", "incoming_call": invitation]) == .malformed)
    #expect(PushWire.parse(invitation) == .malformed)
    let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    guard
      case .fallback(let payload, let ended) = IncomingPushPolicy.plan(
        .malformed, mustReport: true, fallbackIdentity: id)
    else {
      Issue.record("A required malformed push must still report an incoming conversation")
      return
    }
    #expect(
      payload.eventId == id.uuidString && payload.caller.value == "unknown" && !payload.hasVideo
        && ended == nil)
    #expect(IncomingPushPolicy.plan(.malformed, mustReport: false, fallbackIdentity: id) == .skip)
  }

  @Test func optionalFieldsRemainLenientAndCallersRemainStrict() throws {
    for wrong in [1, "true", NSNull()] as [Any] {
      var body = invitation
      body["hasVideo"] = wrong
      body["startedAt"] = 42
      body["metadata"] = ["not-an-object"]
      let payload = try #require(PushWire.decodeIncomingInvitation(body))
      #expect(!payload.hasVideo && payload.startedAt == nil && payload.metadata == nil)
    }
    var body = invitation
    body["caller"] = [
      "handleType": "generic", "value": "caller", "displayName": "Name", "hostContactID": 123,
    ]
    #expect(PushWire.decodeIncomingInvitation(body) == nil)
    body = invitation
    body["eventId"] = "  "
    #expect(PushWire.decodeIncomingInvitation(body) == nil)
  }

  @Test func transportReasonsAndFCMEncodingAreValidated() throws {
    for reason in ["remoteEnded", "failed", "unanswered", "answeredElsewhere", "declinedElsewhere"]
    {
      let body = ["eventId": "end", "serverCallId": "s", "reason": reason]
      let ended = try #require(PushWire.decodeCallEnded(body))
      #expect(ended.reason.rawValue == reason)
      let json = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
      #expect(PushWire.parse(["messageType": "callEnded", "callEnded": json]) == .callEnded(ended))
      #expect(PushWire.parse(["messageType": "callEnded", "callEnded": body]) == .malformed)
    }
    #expect(
      PushWire.decodeCallEnded(["eventId": "e", "serverCallId": "s"])?.reason == .remoteEnded)
    #expect(
      PushWire.decodeCallEnded(["eventId": "e", "serverCallId": "s", "reason": "local"]) == nil)
    #expect(PushWire.decodeCallEnded(["eventId": "e", "serverCallId": "s", "reason": 1]) == nil)
  }

  private var invitation: [String: Any] {
    [
      "eventId": "e", "serverCallId": "s",
      "caller": ["handleType": "generic", "value": "caller", "displayName": "Caller"],
    ]
  }
}
