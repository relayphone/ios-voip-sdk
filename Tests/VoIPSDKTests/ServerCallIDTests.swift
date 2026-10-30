import Foundation
import Testing

@testable import VoIPSDK

struct ServerCallIDTests {
  @Test func serverIdentityUsesTheExistingStringWireFormat() throws {
    let id = ServerCallID(rawValue: "server-1")
    #expect(try JSONEncoder().encode(id) == Data(#""server-1""#.utf8))
    #expect(try JSONDecoder().decode(ServerCallID.self, from: Data(#""server-1""#.utf8)) == id)
  }

  @Test func payloadIdentityNamesPreserveTransportKeys() throws {
    let body = Data(
      #"{"eventId":"event-1","serverCallId":"server-1","caller":{"handleType":"generic","value":"caller","displayName":"Caller"}}"#
        .utf8)
    let payload = try JSONDecoder().decode(IncomingCallPayload.self, from: body)
    #expect(payload.eventID == "event-1")
    #expect(payload.serverCallID == ServerCallID(rawValue: "server-1"))
    let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(payload))
    #expect(
      encoded
        == .object([
          "eventId": .string("event-1"), "serverCallId": .string("server-1"),
          "caller": .object([
            "handleType": .string("generic"), "value": .string("caller"),
            "displayName": .string("Caller"),
          ]),
          "hasVideo": .bool(false),
        ]))
  }

  @Test func terminationAndEventContextRetainTheirWireKeys() throws {
    let id = ServerCallID(rawValue: "server-1")
    let termination = CallEndedPayload(eventID: "end-1", serverCallID: id)
    let encoded = try JSONEncoder().encode(termination)
    #expect(
      try JSONDecoder().decode(JSONValue.self, from: encoded)
        == .object([
          "eventId": .string("end-1"), "serverCallId": .string("server-1"),
          "reason": .string("remoteEnded"),
        ]))
    #expect(try JSONDecoder().decode(CallEndedPayload.self, from: encoded) == termination)

    let event = ConversationEventContext(
      type: .answeredElsewhere, serverCallID: id, eventID: "end-1")
    #expect(
      try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(event))
        == .object([
          "type": .string("answeredElsewhere"), "serverCallID": .string("server-1"),
          "eventID": .string("end-1"),
        ]))
  }
}
