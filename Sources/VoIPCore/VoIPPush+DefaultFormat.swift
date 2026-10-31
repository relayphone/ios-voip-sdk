public import Foundation

extension VoIPPush {
  /// Decodes a VoIP push in the SDK's default JSON format, or returns ``unrecognized``.
  ///
  /// An incoming call is an `incomingCall` object:
  ///
  /// ```json
  /// {
  ///   "incomingCall": {
  ///     "eventId": "event-1",
  ///     "serverCallId": "call-1",
  ///     "caller": { "handleType": "phone", "value": "+14155550123", "displayName": "Alice" },
  ///     "hasVideo": false,
  ///     "metadata": { "room": "room-1", "route": { "region": "eu", "attempt": 2 } }
  ///   }
  /// }
  /// ```
  ///
  /// The server call ID becomes the ``CallID`` and the event ID the ``EventID``. The caller's
  /// `handleType` is `phone`, `email` or `generic`. A phone number may contain spaces,
  /// parentheses, hyphens and periods, which are removed; it must then be in E.164 format.
  /// `hasVideo` and `metadata` are optional. `metadata` is an object of any JSON values, which
  /// becomes the call's ``IncomingCall/metadata``; a `metadata` that isn't an object is ignored.
  /// The older `incoming_call` key is accepted too.
  ///
  /// A server event is a `callEnded` message whose body is a JSON string:
  ///
  /// ```json
  /// {
  ///   "messageType": "callEnded",
  ///   "callEnded": "{\"eventId\":\"event-2\",\"serverCallId\":\"call-1\",\"reason\":\"failed\"}"
  /// }
  /// ```
  ///
  /// Its `reason` is `remoteEnded` (the default), `failed`, `unanswered`, `answeredElsewhere` or
  /// `declinedElsewhere`.
  ///
  /// - Parameter payload: The push's JSON payload.
  public init(defaultFormat payload: Data) {
    self = (try? JSONDecoder().decode(DefaultFormat.self, from: payload))?.push ?? .unrecognized
  }
}

/// The SDK's default VoIP push format.
private struct DefaultFormat: Decodable {
  let push: VoIPPush

  private enum CodingKeys: String, CodingKey {
    case incomingCall
    case olderIncomingCall = "incoming_call"
    case messageType, callEnded
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    // The canonical key wins even when its value is invalid.
    let key: CodingKeys? =
      values.contains(.incomingCall)
      ? .incomingCall : values.contains(.olderIncomingCall) ? .olderIncomingCall : nil
    if let key {
      let call = try values.decode(IncomingCallBody.self, forKey: key)
      push = .incoming(call.incoming, eventID: call.eventID)
    } else if try values.decodeIfPresent(String.self, forKey: .messageType) == "callEnded" {
      let body = try values.decode(String.self, forKey: .callEnded)
      let ended = try JSONDecoder().decode(CallEndedBody.self, from: Data(body.utf8))
      push = .serverEvent(ended.event, for: ended.callID, eventID: ended.eventID)
    } else {
      push = .unrecognized
    }
  }
}

private struct IncomingCallBody: Decodable {
  let eventID: EventID
  let incoming: IncomingCall

  private enum CodingKeys: String, CodingKey {
    case eventID = "eventId"
    case serverCallID = "serverCallId"
    case caller, hasVideo, metadata
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    eventID = try EventID(rawValue: values.decodeIdentifier(forKey: .eventID))
    let callID = try CallID(rawValue: values.decodeIdentifier(forKey: .serverCallID))
    let caller = try values.decode(CallerBody.self, forKey: .caller)
    incoming = IncomingCall(
      id: callID, parties: [caller.party],
      hasVideo: (try? values.decode(Bool.self, forKey: .hasVideo)) ?? false,
      metadata: (try? values.decode([String: JSONValue].self, forKey: .metadata)) ?? [:])
  }
}

private struct CallerBody: Decodable {
  let party: Party

  private enum HandleType: String, Decodable {
    case phone, email, generic
  }

  private enum CodingKeys: String, CodingKey {
    case handleType, value, displayName
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    var value = try values.decode(String.self, forKey: .value)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let kind: Handle.Kind
    switch try values.decode(HandleType.self, forKey: .handleType) {
    case .phone:
      kind = .phoneNumber
      value.removeAll { " ()-.".contains($0) }
    case .email:
      kind = .emailAddress
      let parts = value.split(separator: "@", omittingEmptySubsequences: false)
      guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
        !value.contains(where: \.isWhitespace)
      else { throw values.corrupted(.value, "Invalid email address") }
    case .generic:
      kind = .generic
    }
    let name = try values.decodeIfPresent(String.self, forKey: .displayName)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      party = try Party(
        handle: Handle(kind: kind, value: value), displayName: name?.isEmpty == false ? name : nil)
    } catch {
      throw values.corrupted(.value, "Invalid handle: \(error)")
    }
  }
}

private struct CallEndedBody: Decodable {
  let eventID: EventID
  let callID: CallID
  let event: ServerEvent

  private enum Reason: String, Decodable {
    case remoteEnded, failed, unanswered, answeredElsewhere, declinedElsewhere
  }

  private enum CodingKeys: String, CodingKey {
    case eventID = "eventId"
    case serverCallID = "serverCallId"
    case reason
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    eventID = try EventID(rawValue: values.decodeIdentifier(forKey: .eventID))
    callID = try CallID(rawValue: values.decodeIdentifier(forKey: .serverCallID))
    event =
      switch try values.decodeIfPresent(Reason.self, forKey: .reason) ?? .remoteEnded {
      case .remoteEnded: .endedRemotely
      case .failed: .failed
      case .unanswered: .unanswered
      case .answeredElsewhere: .answeredElsewhere
      case .declinedElsewhere: .declinedElsewhere
      }
  }
}

extension KeyedDecodingContainer {
  /// Decodes an identifier, which must contain a non-whitespace character.
  fileprivate func decodeIdentifier(forKey key: Key) throws -> String {
    let identifier = try decode(String.self, forKey: key)
    guard identifier.contains(where: { !$0.isWhitespace }) else {
      throw corrupted(key, "Empty identifier")
    }
    return identifier
  }

  fileprivate func corrupted(_ key: Key, _ description: String) -> DecodingError {
    .dataCorruptedError(forKey: key, in: self, debugDescription: description)
  }
}
