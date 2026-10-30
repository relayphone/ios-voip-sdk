import Foundation

/// JSON without untyped, non-Sendable dictionaries at the native/JavaScript boundary.
public enum JSONValue: Codable, Sendable, Equatable {
  case string(String), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
  /// A signed 64-bit integer, preserved without a floating-point conversion.
  case int(Int64)
  /// A fractional number or a number outside the signed 64-bit integer range.
  case double(Double)

  public init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() { self = .null }
    else if let x = try? value.decode(Bool.self) { self = .bool(x) }
    else if let x = try? value.decode(String.self) { self = .string(x) }
    else if let x = try? value.decode(Int64.self) { self = .int(x) }
    else if let x = try? value.decode(Double.self) { self = .double(x) }
    else if let x = try? value.decode([String: JSONValue].self) { self = .object(x) }
    else { self = .array(try value.decode([JSONValue].self)) }
  }

  public func encode(to encoder: any Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .string(let x): try value.encode(x)
    case .int(let x): try value.encode(x)
    case .double(let x): try value.encode(x)
    case .bool(let x): try value.encode(x)
    case .object(let x): try value.encode(x)
    case .array(let x): try value.encode(x)
    case .null: try value.encodeNil()
    }
  }
}

public struct Participant: Codable, Sendable, Equatable {
  public var id: String
  public var displayName: String?
  public var avatarUrl: String?
  public var phoneNumber: String?
  public var email: String?

  public init(id: String, displayName: String? = nil, avatarUrl: String? = nil,
              phoneNumber: String? = nil, email: String? = nil) {
    self.id = id; self.displayName = displayName; self.avatarUrl = avatarUrl
    self.phoneNumber = phoneNumber; self.email = email
  }
}

/// Host-supplied system calling identity. No address-book lookup or type inference.
public struct Caller: Codable, Sendable, Equatable {
  public enum HandleType: String, Codable, Sendable { case phone, email, generic }
  public enum ValidationError: Error, Sendable { case invalidValue, invalidDisplayName, invalidHostContactID }
  public let handleType: HandleType
  public let value: String
  public let displayName: String
  /// Opaque identifier in the host's contact store, not a CNContact identifier.
  public let hostContactID: String?

  public init(handleType: HandleType, value: String, displayName: String, hostContactID: String? = nil) throws {
    let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.validText(name) else { throw ValidationError.invalidDisplayName }
    var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if handleType == .phone {
      // The host supplies a country code. Never guess a region or strip extensions.
      let separators = CharacterSet(charactersIn: " ()-.")
      normalized = String(String.UnicodeScalarView(normalized.unicodeScalars.filter { !separators.contains($0) }))
      guard normalized.first == "+", (2...15).contains(normalized.dropFirst().count),
            normalized.dropFirst().allSatisfy({ $0.isASCII && $0 >= "0" && $0 <= "9" }),
            normalized.dropFirst().first != "0" else { throw ValidationError.invalidValue }
    } else {
      guard Self.validText(normalized) else { throw ValidationError.invalidValue }
      if handleType == .email {
        let parts = normalized.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
              normalized.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { throw ValidationError.invalidValue }
      }
    }
    let contact = hostContactID?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let contact, !Self.validText(contact) { throw ValidationError.invalidHostContactID }
    self.handleType = handleType; self.value = normalized; self.displayName = name; self.hostContactID = contact
  }

  static let unknown = Caller()
  private init() {
    handleType = .generic; value = "unknown"; displayName = "Unknown caller"; hostContactID = nil
  }

  private static func validText(_ value: String) -> Bool {
    !value.isEmpty && value.rangeOfCharacter(from: .controlCharacters) == nil
  }

  private enum CodingKeys: String, CodingKey { case handleType, value, displayName, hostContactID }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(handleType: values.decode(HandleType.self, forKey: .handleType),
      value: values.decode(String.self, forKey: .value), displayName: values.decode(String.self, forKey: .displayName),
      hostContactID: values.decodeIfPresent(String.self, forKey: .hostContactID))
  }

  public var participant: Participant {
    Participant(id: value, displayName: displayName,
      phoneNumber: handleType == .phone ? value : nil, email: handleType == .email ? value : nil)
  }
}

/// A validated transport invitation with a typed caller and optional timestamp and metadata.
public struct IncomingCallPayload: Codable, Sendable, Equatable {
  public var eventId: String
  public var serverCallId: String
  public var caller: Caller
  public var hasVideo: Bool
  /// The transport's RFC3339 timestamp as an instant, when valid.
  public var startedAt: Date?
  public var metadata: [String: JSONValue]?

  /// Creates an invitation using an already parsed timestamp.
  public init(eventId: String, serverCallId: String, caller: Caller, hasVideo: Bool = false,
              startedAt: Date? = nil, metadata: [String: JSONValue]? = nil) {
    self.eventId = eventId; self.serverCallId = serverCallId; self.caller = caller
    self.hasVideo = hasVideo; self.startedAt = startedAt; self.metadata = metadata
  }

  private enum CodingKeys: String, CodingKey { case eventId, serverCallId, caller, hasVideo, startedAt, metadata }

  /// Decodes required identity/caller fields and tolerates invalid optional fields.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    eventId = try values.decode(String.self, forKey: .eventId)
    serverCallId = try values.decode(String.self, forKey: .serverCallId)
    guard !eventId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !serverCallId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Empty invitation identity"))
    }
    caller = try values.decode(Caller.self, forKey: .caller)
    hasVideo = (try? values.decode(Bool.self, forKey: .hasVideo)) ?? false
    startedAt = (try? values.decode(String.self, forKey: .startedAt)).flatMap(PushTimestamp.parse)
    metadata = try? values.decode([String: JSONValue].self, forKey: .metadata)
  }

  /// Encodes timestamps as RFC3339 UTC strings with millisecond precision.
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(eventId, forKey: .eventId)
    try values.encode(serverCallId, forKey: .serverCallId)
    try values.encode(caller, forKey: .caller)
    try values.encode(hasVideo, forKey: .hasVideo)
    try values.encodeIfPresent(startedAt?.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)), forKey: .startedAt)
    try values.encodeIfPresent(metadata, forKey: .metadata)
  }
}

/// Foundation parses the instant; full consumption and a local-time round trip
/// reject trailing text, normalized calendar dates and invalid offset minutes.
private enum PushTimestamp {
  static func parse(_ text: String) -> Date? {
    let text = text.uppercased()
    guard text.count >= 20,
          let match = text.wholeMatch(of: Date.ISO8601FormatStyle(includingFractionalSeconds: text.contains("."))) else { return nil }
    let offset: Int
    if text.hasSuffix("Z") { offset = 0 }
    else {
      let zone = Array(text.suffix(6).utf8)
      guard zone.count == 6, zone[0] == 43 || zone[0] == 45, zone[3] == 58,
            [zone[1], zone[2], zone[4], zone[5]].allSatisfy({ (48...57).contains($0) }) else { return nil }
      let hours = Int(zone[1] - 48) * 10 + Int(zone[2] - 48)
      let minutes = Int(zone[4] - 48) * 10 + Int(zone[5] - 48)
      guard hours <= 23, minutes <= 59 else { return nil }
      offset = (hours * 3600 + minutes * 60) * (zone[0] == 45 ? -1 : 1)
    }
    let date = match.output
    guard date.addingTimeInterval(TimeInterval(offset)).formatted(.iso8601).prefix(19) == text.prefix(19),
          !text.hasPrefix("0000") else { return nil }
    return date
  }
}

/// A backend termination; decoded reasons must describe a remote system outcome.
public struct CallEndedPayload: Codable, Sendable, Equatable {
  public var eventId: String
  public var serverCallId: String
  public var reason: ConversationEndedReason
  public init(eventId: String, serverCallId: String, reason: ConversationEndedReason = .remoteEnded) {
    self.eventId = eventId; self.serverCallId = serverCallId; self.reason = reason
  }

  private enum CodingKeys: String, CodingKey { case eventId, serverCallId, reason }

  /// Rejects unknown and receiver-local transport reasons; a missing reason defaults to remoteEnded.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    eventId = try values.decode(String.self, forKey: .eventId)
    serverCallId = try values.decode(String.self, forKey: .serverCallId)
    reason = try values.decodeIfPresent(ConversationEndedReason.self, forKey: .reason) ?? .remoteEnded
    guard !eventId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !serverCallId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          reason != .local else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid transport termination"))
    }
  }
}

public enum ConversationDirection: String, Codable, Sendable { case incoming, outgoing }
public enum ConversationStatus: String, Codable, Sendable {
  case ringing, dialing, connecting, connected, held, ending, ended
}
public enum ConversationEndedReason: String, Codable, Sendable {
  case local, remoteEnded, failed, unanswered, answeredElsewhere, declinedElsewhere
}
public struct ConversationCapabilities: Codable, Sendable, Equatable {
  public var hold: Bool
  public var merge: Bool
  public var tones: Bool
  public var video: Bool
  public init(hold: Bool = true, merge: Bool = true, tones: Bool = true, video: Bool = true) {
    self.hold = hold; self.merge = merge; self.tones = tones; self.video = video
  }
}
public struct ConversationEnded: Codable, Sendable, Equatable {
  public var at: Date
  public var reason: ConversationEndedReason
  public init(at: Date, reason: ConversationEndedReason) { self.at = at; self.reason = reason }
}
public enum ConversationActionKind: String, Codable, Sendable {
  case join, start, end, hold, mute, tones, merge, unmerge
}
public enum ConversationActionOrigin: String, Codable, Sendable { case system, app }
public struct PendingAction: Codable, Sendable, Equatable {
  public var id: UUID
  public var kind: ConversationActionKind
  /// Application deadline: the earlier advertised timeout or conservative action bound,
  /// minus 3 seconds for start/join audio fulfillment, otherwise 1.5 seconds.
  public var deadline: Date
  public var origin: ConversationActionOrigin
  public var held: Bool?
  public var muted: Bool?
  public var digits: String?
  public init(id: UUID, kind: ConversationActionKind, deadline: Date,
              origin: ConversationActionOrigin, held: Bool? = nil, muted: Bool? = nil,
              digits: String? = nil) {
    self.id = id; self.kind = kind; self.deadline = deadline; self.origin = origin
    self.held = held; self.muted = muted; self.digits = digits
  }
}
public struct ConversationSnapshot: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID
  public var direction: ConversationDirection
  public var status: ConversationStatus
  public var members: [Participant]
  public var capabilities: ConversationCapabilities
  public var isMuted: Bool
  public var isVideo: Bool
  public var connectedAt: Date?
  public var ended: ConversationEnded?
  public var payload: IncomingCallPayload?
  public var pending: PendingAction?
}
public enum ConversationReport: Sendable {
  case connecting
  case connected
  case updated(members: [Participant]?, video: Bool?)
  case ended(ConversationEndedReason)
}
public enum IncomingReportSource: Sendable { case foreground, pushKit }
public enum UnhandledActionPolicy: String, Codable, Sendable { case fail, accept }
public enum ConversationClientError: Error, Sendable, Equatable {
  case alreadyConfigured, invalidConfiguration, invalidPayload, unknownConversation, unsupported, invalidDigits, duplicateSDKLinkage, atCapacity
}

public struct ConversationStateUpdate: Codable, Sendable, Equatable {
  public let revision: UInt64
  public let conversations: [ConversationSnapshot]
}

public enum ConversationEvent: String, Codable, Sendable {
  case audioActivated, audioDeactivated, audioActivationMissing, audioActivationFailed, providerReset, providerOwnershipLost, answeredElsewhere
}

public struct ConversationEventContext: Codable, Sendable, Equatable {
  public let type: ConversationEvent
  /// Absent for process-wide system callbacks and reset/ownership events.
  public let conversationID: UUID?
  public let serverCallID: String?
  public let eventID: String?
  public init(type: ConversationEvent, conversationID: UUID? = nil,
              serverCallID: String? = nil, eventID: String? = nil) {
    self.type = type; self.conversationID = conversationID
    self.serverCallID = serverCallID; self.eventID = eventID
  }
}
