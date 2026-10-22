import Foundation
import CoreFoundation

public enum ParsedVoIPPush: Sendable, Equatable {
  case incoming(IncomingCallPayload)
  case callEnded(CallEndedPayload)
  case malformed
}

/// Synchronous decoding keeps untyped PushKit dictionaries out of asynchronous work.
public enum PushWire {
  public static func parse(_ dictionary: [AnyHashable: Any]) -> ParsedVoIPPush {
    // Presence, not successful parsing, selects the canonical invitation envelope.
    if let value = dictionary["incomingCall"] {
      return parseInvitationEnvelope(value)
    }
    if let value = dictionary["incoming_call"] {
      return parseInvitationEnvelope(value)
    }
    if dictionary["messageType"] as? String == "callEnded",
       let body = dictionary["callEnded"] as? String,
       let data = body.data(using: .utf8),
       let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let ended = decodeCallEnded(value) { return .callEnded(ended) }
    return .malformed
  }

  private static func parseInvitationEnvelope(_ value: Any) -> ParsedVoIPPush {
    guard let body = value as? [String: Any], let payload = decodeIncomingInvitation(body) else { return .malformed }
    return .incoming(payload)
  }

  /// Foreground native/Expo reports pass the inner invitation object.
  public static func decodeIncomingInvitation(_ body: [String: Any]) -> IncomingCallPayload? {
    guard let eventID = nonemptyString(body["eventId"]),
          let serverID = nonemptyString(body["serverCallId"]),
          let caller = body["caller"] as? [String: Any],
          let callerID = nonemptyString(caller["id"]) else { return nil }
    let participant = Participant(id: callerID, displayName: caller["displayName"] as? String,
      avatarUrl: caller["avatarUrl"] as? String, phoneNumber: caller["phoneNumber"] as? String,
      email: caller["email"] as? String)
    let video = strictBoolean(body["hasVideo"]) ?? false
    let started = (body["startedAt"] as? String).flatMap(validRFC3339)
    var metadata: [String: JSONValue]?
    if let value = body["metadata"] as? [String: Any], JSONSerialization.isValidJSONObject(value),
       let data = try? JSONSerialization.data(withJSONObject: value) {
      metadata = try? JSONDecoder().decode([String: JSONValue].self, from: data)
    }
    return IncomingCallPayload(eventId: eventID, serverCallId: serverID, caller: participant,
      hasVideo: video, startedAt: started, metadata: metadata)
  }

  /// The FCM callEnded body and native/Expo helper use the same strong model.
  public static func decodeCallEnded(_ body: [String: Any]) -> CallEndedPayload? {
    guard let eventID = nonemptyString(body["eventId"]),
          let serverID = nonemptyString(body["serverCallId"]) else { return nil }
    let reason: ConversationEndedReason
    switch body["reason"] as? String {
    case "failed": reason = .failed
    case "unanswered": reason = .unanswered
    case "answeredElsewhere": reason = .answeredElsewhere
    case "declinedElsewhere": reason = .declinedElsewhere
    default: reason = .remoteEnded
    }
    return CallEndedPayload(eventId: eventID, serverCallId: serverID, reason: reason)
  }

  private static func nonemptyString(_ value: Any?) -> String? {
    guard let value = value as? String,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return value
  }
  private static func strictBoolean(_ value: Any?) -> Bool? {
    guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
    return value.boolValue
  }

  /// Reject invalid calendar dates as well as non-RFC3339 ISO8601 variants.
  private static func validRFC3339(_ value: String) -> String? {
    let pattern = #"\A([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt]([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]+)?(?:[Zz]|([+-])([0-9]{2}):([0-9]{2}))\z"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
    let parts = (1...6).compactMap { index -> Int? in
      guard let range = Range(match.range(at: index), in: value) else { return nil }
      return Int(value[range])
    }
    guard parts.count == 6, (1...9999).contains(parts[0]), (1...12).contains(parts[1]),
          (0...23).contains(parts[3]), (0...59).contains(parts[4]), (0...59).contains(parts[5]) else { return nil }
    if match.range(at: 8).location != NSNotFound {
      guard let hoursRange = Range(match.range(at: 8), in: value),
            let minutesRange = Range(match.range(at: 9), in: value),
            let hours = Int(value[hoursRange]), let minutes = Int(value[minutesRange]),
            hours <= 23, minutes <= 59 else { return nil }
    }
    var calendar = Calendar(identifier: .gregorian)
    guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
    calendar.timeZone = utc
    guard let month = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
          let days = calendar.range(of: .day, in: .month, for: month), days.contains(parts[2]) else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
    return formatter.date(from: value.uppercased()) == nil ? nil : value
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
      caller: Participant(id: "unknown", displayName: "Unknown caller"), hasVideo: false)
    if case .callEnded(let ended) = message { return .fallback(fallback, ended: ended) }
    return .fallback(fallback, ended: nil)
  }
}
