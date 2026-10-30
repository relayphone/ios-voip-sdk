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

/// A backend's opaque call identity, distinct from local conversation and event identifiers.
public struct ServerCallID: RawRepresentable, Codable, Sendable, Hashable {
  /// The exact backend value used in transport and JavaScript payloads.
  public let rawValue: String

  /// Restores a backend identity without changing its spelling.
  /// Incoming payload validation still requires a nonempty, non-whitespace value.
  public init(rawValue: String) { self.rawValue = rawValue }

  /// Decodes the existing string representation of a backend call identity.
  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  /// Encodes the identity as a string, preserving the existing wire format.
  public func encode(to encoder: any Encoder) throws {
    var value = encoder.singleValueContainer()
    try value.encode(rawValue)
  }
}

/// A validated transport invitation with a typed caller and optional timestamp and metadata.
public struct IncomingCallPayload: Codable, Sendable, Equatable {
  /// The backend event identity used to deduplicate invitation deliveries.
  public var eventID: String
  /// The backend call identity shared by invitations and termination notifications.
  public var serverCallID: ServerCallID
  public var caller: Caller
  public var hasVideo: Bool
  /// The transport's RFC3339 timestamp as an instant, when valid.
  public var startedAt: Date?
  public var metadata: [String: JSONValue]?

  /// Creates an invitation using an already parsed timestamp.
  public init(eventID: String, serverCallID: ServerCallID, caller: Caller, hasVideo: Bool = false,
              startedAt: Date? = nil, metadata: [String: JSONValue]? = nil) {
    self.eventID = eventID; self.serverCallID = serverCallID; self.caller = caller
    self.hasVideo = hasVideo; self.startedAt = startedAt; self.metadata = metadata
  }

  private enum CodingKeys: String, CodingKey {
    case eventID = "eventId", serverCallID = "serverCallId"
    case caller, hasVideo, startedAt, metadata
  }

  /// Decodes required identity/caller fields and tolerates invalid optional fields.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    eventID = try values.decode(String.self, forKey: .eventID)
    serverCallID = try values.decode(ServerCallID.self, forKey: .serverCallID)
    guard !eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !serverCallID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
    try values.encode(eventID, forKey: .eventID)
    try values.encode(serverCallID, forKey: .serverCallID)
    try values.encode(caller, forKey: .caller)
    try values.encode(hasVideo, forKey: .hasVideo)
    try values.encodeIfPresent(startedAt?.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)), forKey: .startedAt)
    try values.encodeIfPresent(metadata, forKey: .metadata)
  }
}

/// Foundation validates calendar fields separately from fractional time rounding.
/// Normalize long fractions to nanoseconds and offsets to UTC for its parser.
private enum PushTimestamp {
  static func parse(_ text: String) -> Date? {
    let text = text.uppercased()
    guard text.count >= 20 else { return nil }
    let offset: Int
    let local: Substring
    if text.hasSuffix("Z") { offset = 0; local = text.dropLast() }
    else {
      let zone = Array(text.suffix(6).utf8)
      guard zone.count == 6, zone[0] == 43 || zone[0] == 45, zone[3] == 58,
            [zone[1], zone[2], zone[4], zone[5]].allSatisfy({ (48...57).contains($0) }) else { return nil }
      let hours = Int(zone[1] - 48) * 10 + Int(zone[2] - 48)
      let minutes = Int(zone[4] - 48) * 10 + Int(zone[5] - 48)
      guard hours <= 23, minutes <= 59 else { return nil }
      offset = (hours * 3600 + minutes * 60) * (zone[0] == 45 ? -1 : 1)
      local = text.dropLast(6)
    }
    guard local.count >= 19 else { return nil }
    let suffix = local.dropFirst(19)
    let fraction: String
    if suffix.isEmpty { fraction = "" }
    else {
      let digits = suffix.dropFirst()
      guard suffix.first == ".", !digits.isEmpty,
            digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
      fraction = "." + digits.prefix(9)
    }
    let calendarText = String(local.prefix(19)) + "Z"
    guard let calendar = calendarText.wholeMatch(of: Date.ISO8601FormatStyle()),
          calendar.output.formatted(.iso8601).prefix(19) == local.prefix(19),
          !text.hasPrefix("0000") else { return nil }
    let normalized = String(local.prefix(19)) + fraction + "Z"
    guard let match = normalized.wholeMatch(of: Date.ISO8601FormatStyle(includingFractionalSeconds: !fraction.isEmpty)) else { return nil }
    return match.output.addingTimeInterval(TimeInterval(-offset))
  }
}

/// A backend termination; decoded reasons must describe a remote system outcome.
public struct CallEndedPayload: Codable, Sendable, Equatable {
  /// The backend event identity used to deduplicate termination notifications.
  public var eventID: String
  /// The backend call to terminate.
  public var serverCallID: ServerCallID
  public var reason: ConversationEndedReason
  /// Creates a backend termination associated with a typed call identity.
  public init(eventID: String, serverCallID: ServerCallID, reason: ConversationEndedReason = .remoteEnded) {
    self.eventID = eventID; self.serverCallID = serverCallID; self.reason = reason
  }

  private enum CodingKeys: String, CodingKey {
    case eventID = "eventId", serverCallID = "serverCallId", reason
  }

  /// Rejects unknown and receiver-local transport reasons; a missing reason defaults to remoteEnded.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    eventID = try values.decode(String.self, forKey: .eventID)
    serverCallID = try values.decode(ServerCallID.self, forKey: .serverCallID)
    reason = try values.decodeIfPresent(ConversationEndedReason.self, forKey: .reason) ?? .remoteEnded
    guard !eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !serverCallID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
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
/// Failures when configuring or starting the process's VoIP services.
public enum VoIPStartupError: Error, Sendable, Equatable {
  /// Services already use a different configuration or media adapter.
  case alreadyConfigured
  /// A configuration value has an invalid type or range.
  case invalidConfiguration
  /// More than one linked SDK image attempted to own the process.
  case duplicateSDKLinkage
  /// Simulator activation already occurred with a different configuration.
  case simulatorAlreadyActivated
  /// The configured services could not register their native push receiver.
  case pushRegistration(PushRegistrationError)
}

/// Failures when registering the process's native push receiver.
public enum PushRegistrationError: Error, Sendable, Equatable {
  /// Registration was attempted outside the main thread.
  case wrongExecutor
  /// The native receiver is incomplete.
  case invalidReceiver
  /// The process already owns a different receiver.
  case receiverAlreadyRegistered
  /// PushKit could not create the process registry.
  case registryUnavailable
  /// An unrecognized system failure, without its potentially private user info.
  case systemFailure(domain: String, code: Int)
}

/// Failures when submitting an outgoing conversation or an action request.
/// Request acceptance does not imply later handler fulfillment or connection.
public enum ConversationActionError: Error, Sendable, Equatable {
  /// An outgoing participant has an empty identifier.
  case invalidParticipant
  /// The requested conversation is no longer active.
  case unknownConversation
  /// The requested tones are empty or contain unsupported digits.
  case invalidDigits
  /// A conversation cannot be merged with itself.
  case cannotMergeSameConversation
  /// The system has reached its conversation capacity.
  case atCapacity
  /// The system operation was cancelled.
  case cancelled
  /// An unrecognized system failure, without its potentially private user info.
  case systemFailure(domain: String, code: Int)
}

/// Failures when reporting an incoming invitation from the foreground.
/// PushKit delivery uses the same intake but settles its native completion separately.
public enum IncomingConversationError: Error, Sendable, Equatable {
  /// The invitation has an empty event, server-call or caller identifier.
  case invalidPayload
  /// The manager reset before the pending report could establish ownership.
  case providerReset
  /// The system reports an existing UUID without SDK ownership of that UUID.
  case alreadyReported
  /// The system report was cancelled.
  case cancelled
  /// An unrecognized system failure, without its potentially private user info.
  case systemFailure(domain: String, code: Int)
}

/// Failures when publishing backend state or requesting a local end.
public enum ConversationReportError: Error, Sendable, Equatable {
  /// The conversation is unknown to the manager or SDK.
  case unknownConversation
  /// An updated member has an empty identifier.
  case invalidMembers
  /// The requested end reason cannot be reported to the system.
  case unsupportedEndReason
  /// A local end's action request was rejected before handler fulfillment.
  case action(ConversationActionError)
}

public struct ConversationStateUpdate: Codable, Sendable, Equatable {
  public let revision: UInt64
  public let conversations: [ConversationSnapshot]
}

public enum ConversationEvent: String, Codable, Sendable {
  case audioActivated, audioDeactivated, audioActivationMissing, audioActivationFailed, providerReset, answeredElsewhere
}

public struct ConversationEventContext: Codable, Sendable, Equatable {
  public let type: ConversationEvent
  /// Absent for process-wide system callbacks and reset events.
  public let conversationID: UUID?
  /// The backend call associated with this event, when present.
  public let serverCallID: ServerCallID?
  public let eventID: String?
  public init(type: ConversationEvent, conversationID: UUID? = nil,
              serverCallID: ServerCallID? = nil, eventID: String? = nil) {
    self.type = type; self.conversationID = conversationID
    self.serverCallID = serverCallID; self.eventID = eventID
  }
}
