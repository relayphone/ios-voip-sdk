import Foundation
import Testing

@testable import VoIPSDK

struct ModelTests {
  @Test(arguments: [
    JSONValue.string("value"), .number(42.5), .bool(true), .null,
    .array([.number(1), .string("two")]), .object(["flag": .bool(false)]),
  ])
  func jsonValuesRoundTrip(value: JSONValue) throws {
    #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
  }

  @Test func snapshotRoundTripsWithActionAndEndState() throws {
    let timestamp = Date(timeIntervalSince1970: 1_000)
    let caller = try Caller(handleType: .generic, value: "caller", displayName: "Caller")
    let snapshot = ConversationSnapshot(
      id: UUID(), direction: .incoming, status: .ended, members: [caller.participant],
      capabilities: ConversationCapabilities(hold: false), isMuted: true, isVideo: false,
      connectedAt: timestamp, ended: ConversationEnded(at: timestamp, reason: .remoteEnded),
      payload: IncomingCallPayload(
        eventId: "event", serverCallId: "server", caller: caller,
        metadata: ["nested": .array([.null, .bool(true)])]),
      pending: PendingAction(
        id: UUID(), kind: .mute, deadline: timestamp, origin: .app, muted: true))
    #expect(
      try JSONDecoder().decode(ConversationSnapshot.self, from: JSONEncoder().encode(snapshot))
        == snapshot)
  }

  @Test func capabilitiesDefaultToSupported() {
    let capabilities = ConversationCapabilities()
    #expect(capabilities.hold && capabilities.merge && capabilities.tones && capabilities.video)
  }

  @Test func eventContextPreservesIdentifiers() throws {
    let event = ConversationEventContext(
      type: .answeredElsewhere, conversationID: UUID(),
      serverCallID: "server", eventID: "event")
    #expect(
      try JSONDecoder().decode(ConversationEventContext.self, from: JSONEncoder().encode(event))
        == event)
    #expect(ConversationEventContext(type: .providerReset).conversationID == nil)
  }
}
