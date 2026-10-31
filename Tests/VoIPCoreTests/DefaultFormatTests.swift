import Foundation
import Testing
import VoIPCore

@Suite struct DefaultFormatTests {
  private func decode(_ json: String) -> VoIPPush {
    VoIPPush(defaultFormat: Data(json.utf8))
  }

  private func caller(_ handleType: String, _ value: String, name: String = "Alice") -> String {
    #"{"handleType":"\#(handleType)","value":"\#(value)","displayName":"\#(name)"}"#
  }

  private func incoming(caller: String, extra: String = "", key: String = "incomingCall")
    -> String
  {
    #"{"\#(key)":{"eventId":"event-1","serverCallId":"call-1","caller":\#(caller)\#(extra)}}"#
  }

  @Test func decodesAnIncomingCall() throws {
    let push = decode(
      incoming(
        caller: caller("phone", "+1 (415) 555-0123"),
        extra: #","hasVideo":true,"metadata":{"room":"room-1","attempt":2}"#))
    let expected = IncomingCall(
      id: callID, parties: [alice], hasVideo: true, metadata: ["room": "room-1", "attempt": 2])
    #expect(push == .incoming(expected, eventID: EventID(rawValue: "event-1")))
  }

  @Test func keepsNestedMetadata() {
    let push = decode(
      incoming(
        caller: caller("phone", "+14155550123"),
        extra: #","metadata":{"route":{"region":"eu","hops":["sip",2.5,true,null]},"empty":{}}"#))
    let metadata: [String: JSONValue] = [
      "route": ["region": "eu", "hops": ["sip", 2.5, true, .null]], "empty": [:],
    ]
    let expected = IncomingCall(id: callID, parties: [alice], metadata: metadata)
    #expect(push == .incoming(expected, eventID: EventID(rawValue: "event-1")))
  }

  @Test(arguments: [#""room-1""#, "null", "[1]", "2"])
  func ignoresMetadataThatIsNotAnObject(_ metadata: String) {
    let push = decode(
      incoming(caller: caller("phone", "+14155550123"), extra: #","metadata":\#(metadata)"#))
    let expected = IncomingCall(id: callID, parties: [alice])
    #expect(push == .incoming(expected, eventID: EventID(rawValue: "event-1")))
  }

  @Test(arguments: [
    ("email", "alice@example.com", Handle.Kind.emailAddress), ("generic", "user-42", .generic),
  ])
  func decodesOtherHandles(_ type: String, _ value: String, _ kind: Handle.Kind) throws {
    let push = decode(incoming(caller: caller(type, value, name: " ")))
    let party = Party(handle: try Handle(kind: kind, value: value))
    #expect(
      push
        == .incoming(
          IncomingCall(id: callID, parties: [party]), eventID: EventID(rawValue: "event-1")))
  }

  @Test func acceptsTheOlderKey() {
    let push = decode(incoming(caller: caller("phone", "+14155550123"), key: "incoming_call"))
    let expected = IncomingCall(id: callID, parties: [alice])
    #expect(push == .incoming(expected, eventID: EventID(rawValue: "event-1")))
  }

  @Test(arguments: [
    #"{"incomingCall":{"eventId":"event-1","serverCallId":"call-1"}}"#,
    #"{"incomingCall":{"eventId":" ","serverCallId":"call-1","caller":{"handleType":"generic","value":"a","displayName":"A"}}}"#,
    #"{"incomingCall":{"eventId":"event-1","serverCallId":"call-1","caller":{"handleType":"phone","value":"4155550123","displayName":"A"}}}"#,
    #"{"incomingCall":{"eventId":"event-1","serverCallId":"call-1","caller":{"handleType":"email","value":"alice","displayName":"A"}}}"#,
    #"{"incomingCall":{"eventId":"event-1","serverCallId":"call-1","caller":{"handleType":"fax","value":"a","displayName":"A"}}}"#,
    #"{"incomingCall":null,"incoming_call":{"eventId":"event-1","serverCallId":"call-1","caller":{"handleType":"generic","value":"a","displayName":"A"}}}"#,
    #"{"messageType":"callEnded","callEnded":"{\"eventId\":\"event-2\",\"serverCallId\":\"call-1\",\"reason\":\"local\"}"}"#,
    #"{"messageType":"callEnded","callEnded":{"eventId":"event-2","serverCallId":"call-1"}}"#,
    #"{"aps":{}}"#,
    #"[]"#,
    "not json",
  ])
  func rejectsInvalidPushes(_ json: String) {
    #expect(decode(json) == .unrecognized)
  }

  @Test(arguments: [
    (nil, ServerEvent.endedRemotely), ("remoteEnded", .endedRemotely), ("failed", .failed),
    ("unanswered", .unanswered), ("answeredElsewhere", .answeredElsewhere),
    ("declinedElsewhere", .declinedElsewhere),
  ])
  func decodesAServerEvent(_ reason: String?, _ event: ServerEvent) {
    let reasonField = reason.map { #",\"reason\":\"\#($0)\""# } ?? ""
    let push = decode(
      #"{"messageType":"callEnded","callEnded":"{\"eventId\":\"event-2\",\"serverCallId\":\"call-1\"\#(reasonField)}"}"#
    )
    #expect(push == .serverEvent(event, for: callID, eventID: EventID(rawValue: "event-2")))
  }
}
