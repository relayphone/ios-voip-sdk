import Foundation

public enum ParsedVoIPPush: Sendable, Equatable {
  case incoming(IncomingCallPayload)
  case callEnded(CallEndedPayload)
  case malformed
}

/// Synchronous decoding keeps untyped PushKit dictionaries out of asynchronous work.
public enum PushWire {
  /// Decodes APNs invitation objects or an FCM callEnded JSON string.
  /// The canonical incomingCall key takes precedence even when its value is invalid.
  public static func parse(_ dictionary: [AnyHashable: Any]) -> ParsedVoIPPush {
    let envelope: [String: Any]
    if let value = dictionary["incomingCall"] {
      envelope = ["incomingCall": invitationObject(value)]
    } else if let value = dictionary["incoming_call"] {
      envelope = ["incoming_call": invitationObject(value)]
    } else {
      envelope = ["messageType": dictionary["messageType"] as? String ?? "",
                  "callEnded": dictionary["callEnded"] as? String ?? ""]
    }
    return decode(Envelope.self, from: envelope)?.message ?? .malformed
  }

  /// Foreground native/Expo reports pass the inner invitation object.
  public static func decodeIncomingInvitation(_ body: [String: Any]) -> IncomingCallPayload? {
    decode(IncomingCallPayload.self, from: serializableFields(body))
  }

  /// Unknown reasons and the receiver-local reason are invalid transport terminations.
  /// An absent reason retains the remoteEnded default.
  public static func decodeCallEnded(_ body: [String: Any]) -> CallEndedPayload? {
    if let reason = body["reason"], !JSONSerialization.isValidJSONObject([reason]) { return nil }
    return decode(CallEndedPayload.self, from: serializableFields(body))
  }

  private static func invitationObject(_ object: Any) -> Any {
    guard let body = object as? [String: Any] else { return NSNull() }
    return serializableFields(body)
  }

  // Bridge unsupported native values to null before Codable applies the schema:
  // required fields reject null, optional fields default, and unknown fields are ignored.
  private static func serializableFields(_ body: [String: Any]) -> [String: Any] {
    body.mapValues { JSONSerialization.isValidJSONObject([$0]) ? $0 : NSNull() }
  }

  private static func decode<Value: Decodable>(_ type: Value.Type, from object: Any) -> Value? {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  private struct Envelope: Decodable {
    let message: ParsedVoIPPush
    private enum CodingKeys: String, CodingKey { case incomingCall, incoming_call, messageType, callEnded }

    init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      if values.contains(.incomingCall) {
        message = .incoming(try values.decode(IncomingCallPayload.self, forKey: .incomingCall))
      } else if values.contains(.incoming_call) {
        message = .incoming(try values.decode(IncomingCallPayload.self, forKey: .incoming_call))
      } else if try values.decodeIfPresent(String.self, forKey: .messageType) == "callEnded" {
        let body = try values.decode(String.self, forKey: .callEnded)
        message = .callEnded(try JSONDecoder().decode(CallEndedPayload.self, from: Data(body.utf8)))
      } else {
        message = .malformed
      }
    }
  }
}

/// Required callEnded notifications still need an incoming API attempt; their target
/// termination is applied as well. Actual cold-launch PushKit validation is unmeasured.
enum IncomingPushPlan: Sendable, Equatable {
  case incoming(IncomingCallPayload)
  case callEnded(CallEndedPayload)
  case fallback(IncomingCallPayload, ended: CallEndedPayload?)
  case skip
}
enum IncomingPushPolicy {
  static func plan(_ message: ParsedVoIPPush, mustReport: Bool,
                   fallbackIdentity: UUID = UUID()) -> IncomingPushPlan {
    if case .incoming(let payload) = message { return .incoming(payload) }
    if !mustReport {
      if case .callEnded(let payload) = message { return .callEnded(payload) }
      return .skip
    }
    let fallback = IncomingCallPayload(eventId: fallbackIdentity.uuidString,
      serverCallId: "unrecognized-\(fallbackIdentity.uuidString)",
      caller: .unknown, hasVideo: false)
    if case .callEnded(let ended) = message { return .fallback(fallback, ended: ended) }
    return .fallback(fallback, ended: nil)
  }
}
