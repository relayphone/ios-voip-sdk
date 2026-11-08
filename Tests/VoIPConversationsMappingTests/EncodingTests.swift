import Foundation
import Testing
import VoIPAudio
import VoIPCore

@testable import VoIPConversationsMapping

@Suite("React Native conversation encoding")
struct EncodingTests {
  private let capabilities = JSONValue.object([
    "hold": .bool(true), "merge": .bool(true), "tones": .bool(true), "video": .bool(true),
  ])

  @Test(arguments: ["app-call-42", "MiXeD/Case", "電話 ☎️", "café", "cafe\u{301}"])
  func identityIsTheAppsCallID(_ id: String) throws {
    let options = JSONValue.object([
      "id": .string(id), "to": .object(["id": .string("callee")]), "video": .bool(false),
    ])
    let outgoing = try ConversationEncoding.outgoing(options)
    #expect(outgoing.id.rawValue == id)
    for isIncoming in [false, true] {
      let call = Call(id: outgoing.id, isIncoming: isIncoming, parties: [], status: .connecting)
      let snapshot = ConversationEncoding.conversation(
        call, members: [], capabilities: capabilities)
      #expect(snapshot["id"] == .string(id))
      #expect(snapshot["direction"] == .string(isIncoming ? "incoming" : "outgoing"))
    }
    #expect(PresentationOutcome.presented.json(id: outgoing.id)["id"] == .string(id))
  }

  @Test
  func outgoingRequiresTheAppsIDAndValidOptions() {
    let to = JSONValue.object(["id": .string("callee")])
    for options in [
      JSONValue.object(["to": to, "video": .bool(false)]),
      .object(["id": .string(""), "to": to, "video": .bool(false)]),
      .object(["id": .string("call"), "to": to]),
      .object(["id": .string("call"), "to": .null, "video": .bool(false)]),
    ] {
      #expect(throws: CommandError.self) { try ConversationEncoding.outgoing(options) }
    }
  }

  @Test
  func snapshotCarriesConnectedHeldAndNativeMediaState() {
    let connected = Date(timeIntervalSince1970: 1_800_000_000)
    let call = Call(
      id: CallID(rawValue: "app-call"), isIncoming: false, parties: [], status: .connected,
      isMuted: true, isOnHold: true, hasVideo: true, connectedAt: connected)
    let member = JSONValue.object(["id": .string("callee")])
    let snapshot = ConversationEncoding.conversation(
      call, members: [member], capabilities: capabilities, nativeMedia: true)
    #expect(snapshot["status"] == .string("held"))
    #expect(snapshot["connectedAt"] == .date(connected))
    #expect(snapshot["isMuted"] == .bool(true))
    #expect(snapshot["isVideo"] == .bool(true))
    #expect(snapshot["members"] == .array([member]))
    #expect(snapshot["capabilities"] == capabilities)
    #expect(snapshot["media"] == .string("native"))
    #expect(snapshot["pending"] == nil)
  }

  @Test
  func previewAndFailureReasonsSurviveEncoding() {
    var call = Call(
      id: CallID(rawValue: "call"), isIncoming: true, parties: [],
      status: .previewing(.filtered(.doNotDisturb)))
    let preview = ConversationEncoding.conversation(call, members: [], capabilities: capabilities)
    #expect(
      preview["previewReason"]
        == .object([
          "type": .string("filtered"), "cause": .string("doNotDisturb"),
        ]))
    call.status = .ended(.failed(.notPlaced))
    let ended = ConversationEncoding.conversation(
      call, members: [], capabilities: capabilities, endedAt: Date(timeIntervalSince1970: 0))
    #expect(ended["ended"]?["reason"] == .string("failed"))
    #expect(ended["ended"]?["failure"] == .object(["kind": .string("notPlaced")]))
  }

  @Test
  func everyJoinFailureCarriesItsReason() {
    let call = Call(
      id: CallID(rawValue: "join-id"), isIncoming: true, parties: [], status: .previewing(.policy))
    let failures: [(JoinFailure, JSONValue)] = [
      (.ended, .object(["kind": .string("ended")])),
      (.refused, .object(["kind": .string("refused")])),
      (.frameworkReset, .object(["kind": .string("frameworkReset")])),
      (.failed(.media), .object(["kind": .string("failed"), "failure": .string("media")])),
      (.failed(.notPlaced), .object(["kind": .string("failed"), "failure": .string("notPlaced")])),
    ]
    for (failure, reason) in failures {
      #expect(
        ConversationEncoding.joinFailed(call, failure)
          == .object([
            "conversationId": .string("join-id"), "reason": reason,
          ]))
    }
  }

  @Test
  func nativeActionsEncodeAsInformationalEvents() {
    let id = CallID(rawValue: "native-action-id")
    let call = Call(id: id, isIncoming: true, parties: [], status: .connected)
    let actions: [(Action, JSONValue)] = [
      (.answer(id), .object(["kind": .string("answer")])),
      (.end(id), .object(["kind": .string("end")])),
      (.mute(id, muted: true), .object(["kind": .string("mute"), "muted": .bool(true)])),
      (.hold(id, onHold: true), .object(["kind": .string("hold"), "held": .bool(true)])),
      (
        .playTones(id, digits: "12#"),
        .object(["kind": .string("tones"), "digits": .string("12#")])
      ),
    ]
    for (action, expected) in actions {
      #expect(
        ConversationEncoding.performed(action, call, origin: .system)
          == .object([
            "conversationId": .string(id.rawValue), "origin": .string("system"), "action": expected,
          ]))
    }
  }

  @Test
  func audioRoutesUseTheSDKsIdentifiersAndKinds() {
    let route = AudioRoute(id: .init(rawValue: "sdk-route"), kind: .bluetooth, name: "Headset")
    let value = JSONValue.object([
      "id": .string("sdk-route"), "name": .string("Headset"), "type": .string("bluetooth"),
    ])
    #expect(
      ConversationEncoding.routes([route], current: route)
        == .object([
          "routes": .array([value]), "current": value,
        ]))
    #expect(ConversationEncoding.routes([], current: nil)["current"] == .null)
  }

  @Test
  func bridgeKeepsBooleansNumbersArraysAndNullDistinct() throws {
    let original = JSONValue.object([
      "flag": .bool(true), "count": .number(1), "values": .array([.null, .string("text")]),
    ])
    #expect(JSONValue(original.foundationObject) == original)
    #expect(try JSONDecoder().decode(JSONValue.self, from: original.data()) == original)
    #expect(JSONValue(Date()) == nil)
  }
}
