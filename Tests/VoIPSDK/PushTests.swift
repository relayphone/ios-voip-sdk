import Foundation

@main
struct PushTests {
  @MainActor static func main() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let template = try Data(contentsOf: root.appendingPathComponent("discovery/device/incoming-call.template.json"))
    guard let payload = try JSONSerialization.jsonObject(with: template) as? [String: Any],
          payload["aps"] is [String: Any],
          case .incoming(let templateInvitation) = PushWire.parse(payload) else {
      preconditionFailure("Device QA template must be an actual SDK incomingCall envelope")
    }
    precondition(templateInvitation.eventId == "replace-with-fresh-event-uuid"
      && templateInvitation.serverCallId == "replace-with-fresh-call-uuid"
      && templateInvitation.caller.id == "sdk-device-qa" && !templateInvitation.hasVideo)
    let fallbackID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    for required in [false, true] {
      precondition(IncomingPushPolicy.plan(.incoming(templateInvitation), mustReport: required, fallbackIdentity: fallbackID)
        == .incoming(templateInvitation), "The canonical fixture must take the invitation path for either mustReport value")
    }
    let raw: [String: Any] = ["incomingCall": [
      "eventId": "event-1", "serverCallId": "server-1",
      "caller": ["id": "caller", "displayName": "Fixture"], "hasVideo": true,
      "startedAt": "2026-10-22T00:00:00.125Z", "metadata": ["flag": true, "nested": [1, "two"]]
    ]]
    guard case .incoming(let incoming) = PushWire.parse(raw) else { preconditionFailure("Valid invitation was rejected") }
    precondition(incoming.eventId == "event-1" && incoming.hasVideo && incoming.startedAt != nil)
    precondition(incoming.metadata?["flag"] == .bool(true))
    precondition(PushWire.parse(["incomingCall": "malformed", "incoming_call": raw["incomingCall"]!]) == .malformed,
      "Canonical key must win even when malformed")
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    precondition(IncomingPushPolicy.plan(.malformed, mustReport: false, fallbackIdentity: id) == .skip)
    guard case .fallback(let fallback, _) = IncomingPushPolicy.plan(.malformed, mustReport: true, fallbackIdentity: id) else {
      preconditionFailure("Required malformed push must attempt an incoming report")
    }
    precondition(fallback.eventId == id.uuidString && fallback.caller.id == "unknown" && !fallback.hasVideo)
    precondition(IncomingPushPolicy.plan(.incoming(incoming), mustReport: false, fallbackIdentity: id) == .incoming(incoming))
    precondition(PushWire.parse(["incoming_call": raw["incomingCall"]!]) == .incoming(incoming))
    precondition(PushWire.parse(raw["incomingCall"] as! [String: Any]) == .malformed, "Flat payloads are not APNs invitations")
    let encodedEnvelope = String(data: try JSONSerialization.data(withJSONObject: raw["incomingCall"]!), encoding: .utf8)!
    precondition(PushWire.parse(["incomingCall": encodedEnvelope]) == .malformed, "JSON-string invitation envelopes remain invalid")
    for wrong in [1, "true", NSNull()] as [Any] {
      var body = raw["incomingCall"] as! [String: Any]
      body["hasVideo"] = wrong
      precondition(PushWire.decodeIncomingInvitation(body)?.hasVideo == false, "Only a JSON boolean enables video")
    }
    for invalidDate in ["2026-02-30T12:00:00Z", "2026-10-22", "2026-10-22T25:00:00Z", "2026-10-22T00:00:00", "2026-10-22T00:00:00+25:00", "2026-10-22T00:00:00+01:99"] {
      var body = raw["incomingCall"] as! [String: Any]
      body["startedAt"] = invalidDate
      precondition(PushWire.decodeIncomingInvitation(body)?.startedAt == nil)
    }
    var offsetBody = raw["incomingCall"] as! [String: Any]
    offsetBody["startedAt"] = "2026-10-22T00:00:00+02:00"
    precondition(PushWire.decodeIncomingInvitation(offsetBody)?.startedAt == "2026-10-22T00:00:00+02:00")
    offsetBody["metadata"] = ["array", "not-object"]
    precondition(PushWire.decodeIncomingInvitation(offsetBody)?.metadata == nil)
    for key in ["eventId", "serverCallId"] {
      var body = raw["incomingCall"] as! [String: Any]
      body[key] = "  "
      precondition(PushWire.decodeIncomingInvitation(body) == nil)
    }
    precondition(PushWire.decodeIncomingInvitation(["eventId": "e", "serverCallId": "s", "caller": ["id": 123]]) == nil)
    let endedBody: [String: Any] = ["eventId": "end-event", "serverCallId": "server-1", "reason": "answeredElsewhere"]
    let endedWire: [AnyHashable: Any] = ["messageType": "callEnded", "callEnded": String(data: try JSONSerialization.data(withJSONObject: endedBody), encoding: .utf8)!]
    guard case .callEnded(let ended) = PushWire.parse(endedWire) else { preconditionFailure("FCM callEnded was rejected") }
    precondition(ended.reason == .answeredElsewhere)
    precondition(PushWire.decodeCallEnded(["eventId": "e", "serverCallId": "s", "reason": "unknown"])?.reason == .remoteEnded)
    precondition(PushWire.parse(["messageType": "callEnded", "callEnded": endedBody]) == .malformed)
    precondition(IncomingPushPolicy.plan(.callEnded(ended), mustReport: false, fallbackIdentity: id) == .callEnded(ended))
    guard case .fallback(_, let target) = IncomingPushPolicy.plan(.callEnded(ended), mustReport: true, fallbackIdentity: id) else {
      preconditionFailure("Required callEnded must still attempt an incoming report")
    }
    precondition(target == ended)

    let tokens = PushTokenStore()
    precondition(tokens.state.revision == 0 && tokens.state.token == nil)
    tokens.update(Data([1, 2, 255]))
    precondition(tokens.state.revision == 1 && tokens.state.token?.value == "0102ff")
    tokens.update(Data([1, 2, 255]))
    precondition(tokens.state.revision == 1)
    tokens.update(nil)
    precondition(tokens.state.revision == 2 && tokens.state.token == nil)
    let invalidated = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tokens.state)) as! [String: Any]
    precondition(invalidated["token"] is NSNull, "Invalidation must encode token:null rather than omit token")
    tokens.update(Data())
    precondition(tokens.state.revision == 2)
    var notifications: [PushTokenState] = []
    let subscription = tokens.observe { state in
      notifications.append(state)
      if state.token?.value == "aa" { tokens.update(Data([0xbb])) }
    }
    tokens.update(Data([0xaa]))
    precondition(notifications.map(\.revision) == [2, 3, 4])
    precondition(notifications.last?.token?.value == "bb")
    tokens.removeObserver(subscription)
    tokens.update(nil)
    precondition(notifications.count == 3)
    var hydrated: PushTokenState?
    let hydrateSubscription = tokens.observe { hydrated = $0 }
    precondition(hydrated?.revision == 5 && hydrated?.token == nil)
    tokens.removeObserver(hydrateSubscription)

    try SimulatorSupport.configure(enabled: false)
    precondition(!SimulatorSupport.activateIfNeeded())
    do {
      try SimulatorSupport.configure(enabled: true)
      preconditionFailure("An activation request must lock the launch preference")
    } catch SimulatorSupport.ConfigurationError.activationAlreadyRequested {}
    try SimulatorSupport.configure(enabled: false)
    print("Push tests passed: device QA template, envelope/JSON/date parsing, required-report policy, FCM end, token hydration/invalidation/reentrancy and simulator preference")
  }
}
