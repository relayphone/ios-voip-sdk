import Foundation

#if SWIFT_PACKAGE
  import VoIPAudio
  import VoIPCore
#endif

/// Values shared by snapshots, lifecycle events and the native command boundary.
enum ConversationEncoding {
  enum Origin: String, Sendable { case system, app }
  static func outgoing(_ options: JSONValue) throws(CommandError) -> OutgoingCall {
    guard let id = options["id"]?.string, !id.isEmpty, let to = options["to"],
      let video = options["video"]?.bool
    else { throw .invalidArguments }
    let party = try Party(participant: to)
    let metadata: [String: JSONValue]
    switch options["metadata"] {
    case .object(let values)?: metadata = values
    case nil: metadata = [:]
    default: throw .invalidArguments
    }
    return OutgoingCall(
      id: CallID(rawValue: id), parties: [party], hasVideo: video, metadata: metadata)
  }

  static func conversation(
    _ call: Call, members: [JSONValue], capabilities: JSONValue,
    payload: JSONValue? = nil, pending: JSONValue? = nil,
    nativeMedia: Bool = false, endedAt: Date = .now
  ) -> JSONValue {
    var fields = call.status.fields(isOnHold: call.isOnHold, endedAt: endedAt)
    fields["id"] = .string(call.id.rawValue)
    fields["direction"] = .string(call.isIncoming ? "incoming" : "outgoing")
    fields["members"] = .array(members)
    fields["capabilities"] = capabilities
    fields["isMuted"] = .bool(call.isMuted)
    fields["isVideo"] = .bool(call.hasVideo)
    if let connectedAt = call.connectedAt { fields["connectedAt"] = .date(connectedAt) }
    fields["payload"] = payload
    fields["pending"] = pending
    if nativeMedia { fields["media"] = .string("native") }
    return .object(fields)
  }

  static func joinFailed(_ call: Call, _ failure: JoinFailure) -> JSONValue {
    let reason: JSONValue =
      switch failure {
      case .ended: .object(["kind": .string("ended")])
      case .refused: .object(["kind": .string("refused")])
      case .frameworkReset: .object(["kind": .string("frameworkReset")])
      case .failed(let failure):
        .object(["kind": .string("failed"), "failure": .string(failure.kind)])
      }
    return .object(["conversationId": .string(call.id.rawValue), "reason": reason])
  }

  static func performed(_ action: Action, _ call: Call, origin: Origin) -> JSONValue {
    let action: JSONValue =
      switch action {
      case .start: .object(["kind": .string("start")])
      case .unmerge: .object(["kind": .string("unmerge")])
      case .join: .object(["kind": .string("join")])
      case .answer: .object(["kind": .string("answer")])
      case .end: .object(["kind": .string("end")])
      case .hold(_, let held): .object(["kind": .string("hold"), "held": .bool(held)])
      case .mute(_, let muted): .object(["kind": .string("mute"), "muted": .bool(muted)])
      case .playTones(_, let digits):
        .object(["kind": .string("tones"), "digits": .string(digits)])
      case .merge(_, let other):
        .object(["kind": .string("merge"), "with": .string(other.rawValue)])
      }
    return .object([
      "conversationId": .string(call.id.rawValue), "origin": .string(origin.rawValue),
      "action": action,
    ])
  }

  static func routes(_ routes: [AudioRoute], current: AudioRoute?) -> JSONValue {
    .object(["routes": .array(routes.map(route)), "current": current.map(route) ?? .null])
  }

  private static func route(_ route: AudioRoute) -> JSONValue {
    let kind: String =
      switch route.kind {
      case .builtInReceiver: "builtInReceiver"
      case .builtInSpeaker: "builtInSpeaker"
      case .headphones: "headphones"
      case .bluetooth: "bluetooth"
      case .airPlay: "airPlay"
      case .carAudio: "carAudio"
      case .usbAudio: "usbAudio"
      case .other: "other"
      }
    return .object([
      "id": .string(route.id.rawValue), "name": .string(route.name), "type": .string(kind),
    ])
  }
}
