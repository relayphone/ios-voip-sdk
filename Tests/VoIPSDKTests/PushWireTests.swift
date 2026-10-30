import Foundation
import Testing

@testable import VoIPSDK

struct PushWireTests {
  private var invitation: [String: Any] {
    [
      "eventId": "event-1", "serverCallId": "server-1",
      "caller": ["handleType": "generic", "value": "caller", "displayName": "Fixture"],
      "hasVideo": true, "startedAt": "2026-10-22T00:00:00.125Z",
      "metadata": ["flag": true, "nested": [1, "two"]],
    ]
  }

  private func payload() throws -> IncomingCallPayload {
    IncomingCallPayload(
      eventId: "event-1", serverCallId: "server-1",
      caller: try Caller(handleType: .generic, value: "caller", displayName: "Fixture"),
      hasVideo: true, startedAt: "2026-10-22T00:00:00.125Z",
      metadata: ["flag": .bool(true), "nested": .array([.number(1), .string("two")])])
  }

  @Test func parsesCanonicalAndLegacyEnvelopes() throws {
    let expected = try payload()
    #expect(PushWire.parse(["incomingCall": invitation]) == .incoming(expected))
    #expect(PushWire.parse(["incoming_call": invitation]) == .incoming(expected))
  }

  @Test func canonicalKeyWinsEvenWhenMalformed() {
    #expect(
      PushWire.parse(["incomingCall": "malformed", "incoming_call": invitation]) == .malformed)
  }

  @Test func rejectsFlatAndStringInvitationEnvelopes() throws {
    #expect(PushWire.parse(invitation) == .malformed)
    let encoded = String(
      decoding: try JSONSerialization.data(withJSONObject: invitation), as: UTF8.self)
    #expect(PushWire.parse(["incomingCall": encoded]) == .malformed)
  }

  @Test(arguments: ["1", #""true""#, "null"])
  func onlyJSONBooleanEnablesVideo(json: String) throws {
    var body = invitation
    body["hasVideo"] = try JSONSerialization.jsonObject(
      with: Data(json.utf8), options: .fragmentsAllowed)
    #expect(PushWire.decodeIncomingInvitation(body)?.hasVideo == false)
  }

  @Test(arguments: [
    "2026-02-30T12:00:00Z", "2026-10-22", "2026-10-22T25:00:00Z",
    "2026-10-22T00:00:00", "2026-10-22T00:00:00+25:00", "2026-10-22T00:00:00+01:99",
  ])
  func discardsInvalidDates(value: String) throws {
    var body = invitation
    body["startedAt"] = value
    let decoded = try #require(PushWire.decodeIncomingInvitation(body))
    #expect(decoded.startedAt == nil)
  }

  @Test func preservesOriginalDateOffset() {
    var body = invitation
    body["startedAt"] = "2026-10-22T00:00:00+02:00"
    #expect(PushWire.decodeIncomingInvitation(body)?.startedAt == "2026-10-22T00:00:00+02:00")
  }

  @Test func discardsNonObjectMetadata() throws {
    var body = invitation
    body["metadata"] = ["array", "not-object"]
    let decoded = try #require(PushWire.decodeIncomingInvitation(body))
    #expect(decoded.metadata == nil)
  }

  @Test(arguments: ["eventId", "serverCallId"])
  func rejectsBlankIdentifiers(key: String) {
    var body = invitation
    body[key] = "  "
    #expect(PushWire.decodeIncomingInvitation(body) == nil)
  }

  @Test(arguments: [
    #"{"id":123}"#,
    #"{"id":"old-untyped"}"#,
    #"{"handleType":"phone","value":"2025550123","displayName":"Name"}"#,
    #"{"handleType":"other","value":"caller","displayName":"Name"}"#,
    #"{"handleType":"generic","value":"caller"}"#,
    #"{"handleType":"generic","value":"caller","displayName":"Name","hostContactID":123}"#,
  ])
  func invalidCallerRetainsMandatoryReporting(json: String) throws {
    var body = invitation
    body["caller"] = try JSONSerialization.jsonObject(with: Data(json.utf8))
    let parsed = PushWire.parse(["incomingCall": body])
    #expect(parsed == .malformed)
    guard case .fallback = IncomingPushPolicy.plan(parsed, mustReport: true) else {
      Issue.record("An invalid required caller must still attempt an incoming report")
      return
    }
  }

  @Test func parsesFCMEndStringAndRejectsObjectEnvelope() throws {
    let body = ["eventId": "end-event", "serverCallId": "server-1", "reason": "answeredElsewhere"]
    let encoded = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    let ended = CallEndedPayload(
      eventId: "end-event", serverCallId: "server-1", reason: .answeredElsewhere)
    #expect(
      PushWire.parse(["messageType": "callEnded", "callEnded": encoded]) == .callEnded(ended))
    #expect(PushWire.parse(["messageType": "callEnded", "callEnded": body]) == .malformed)
    #expect(
      PushWire.decodeCallEnded(["eventId": "e", "serverCallId": "s", "reason": "unknown"])?.reason
        == .remoteEnded)
  }

  @Test func optionalMalformedPushIsSkipped() {
    #expect(IncomingPushPolicy.plan(.malformed, mustReport: false) == .skip)
  }

  @Test func requiredMalformedPushHasStableFallbackIdentity() {
    let id = UUID()
    guard
      case .fallback(let fallback, let ended) = IncomingPushPolicy.plan(
        .malformed, mustReport: true, fallbackIdentity: id)
    else {
      Issue.record("A required malformed push must attempt an incoming report")
      return
    }
    #expect(fallback.eventId == id.uuidString)
    #expect(fallback.caller.value == "unknown")
    #expect(!fallback.hasVideo)
    #expect(ended == nil)
  }

  @Test(arguments: [false, true])
  func validIncomingPushIsPreserved(mustReport: Bool) throws {
    let incoming = try payload()
    #expect(
      IncomingPushPolicy.plan(.incoming(incoming), mustReport: mustReport) == .incoming(incoming))
  }

  @Test func requiredEndStillReportsIncomingAndRetainsTarget() {
    let ended = CallEndedPayload(
      eventId: "end-event", serverCallId: "server-1", reason: .answeredElsewhere)
    #expect(IncomingPushPolicy.plan(.callEnded(ended), mustReport: false) == .callEnded(ended))
    guard
      case .fallback(_, let target) = IncomingPushPolicy.plan(.callEnded(ended), mustReport: true)
    else {
      Issue.record("A required callEnded must still attempt an incoming report")
      return
    }
    #expect(target == ended)
  }
}
