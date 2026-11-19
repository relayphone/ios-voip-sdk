#if SWIFT_PACKAGE
  // Version-zero interchange types. These model the shared wire contract separately from
  // the engine's current native call and action types.
  package enum SpecV0 {
    package struct ID: Codable, Hashable, Sendable {
      package let rawValue: String

      package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard WireValues.isID(value) else {
          throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid wire ID")
        }
        rawValue = value
      }

      package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
      }

      package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.utf8.elementsEqual(rhs.rawValue.utf8)
      }

      package func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue.utf8.count)
        for byte in rawValue.utf8 {
          hasher.combine(byte)
        }
      }
    }

    package struct Milliseconds: Codable, Sendable {
      package let value: Int64
      package var duration: Duration { .milliseconds(value) }

      package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(Int64.self)
        guard (1...9_007_199_254_740_991).contains(value) else {
          throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "Expected positive safe integer milliseconds")
        }
      }

      package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
      }
    }

    package struct Line: Codable, Sendable {
      package let accountID, id: ID
      package let label: String

      package init(from decoder: any Decoder) throws {
        let object = try Object(decoder)
        try object.requireOnly(.accountID, .id, .label)
        accountID = try object.decode(.accountID)
        id = try object.decode(.id)
        label = try object.text(.label)
      }
    }

    package struct Party: Codable, Sendable {
      package let id: ID
      package let handle: Handle
      package let displayName: String

      package init(from decoder: any Decoder) throws {
        let object = try Object(decoder)
        try object.requireOnly(.id, .handle, .displayName)
        id = try object.decode(.id)
        handle = try object.decode(.handle)
        displayName = try object.text(.displayName)
      }
    }

    package enum Handle: Codable, Sendable {
      case phone(String)
      case email(String)
      case opaque(String)

      private enum Kind: String, Codable { case phone, email, opaque }

      package init(from decoder: any Decoder) throws {
        let object = try Object(decoder)
        switch try object.decode(.kind, as: Kind.self) {
        case .phone:
          try object.requireOnly(.kind, .e164)
          let value = try object.text(.e164)
          guard (try? VoIPCore.Handle(kind: .phoneNumber, value: value)) != nil else {
            throw object.invalid("Invalid E.164 handle")
          }
          self = .phone(value)
        case .email:
          try object.requireOnly(.kind, .address)
          let value = try object.text(.address)
          let parts = value.unicodeScalars.split(separator: "@", omittingEmptySubsequences: false)
          guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
            !value.unicodeScalars.contains(where: WireValues.isWhitespace)
          else { throw object.invalid("Invalid email handle") }
          self = .email(value)
        case .opaque:
          try object.requireOnly(.kind, .value)
          let value = try object.text(.value)
          guard value.unicodeScalars.contains(where: { !WireValues.isWhitespace($0) }) else {
            throw object.invalid("Blank opaque handle")
          }
          self = .opaque(value)
        }
      }

      package func encode(to encoder: any Encoder) throws {
        var object = encoder.container(keyedBy: Key.self)
        switch self {
        case .phone(let value):
          try object.encode(Kind.phone, forKey: .kind)
          try object.encode(value, forKey: .e164)
        case .email(let value):
          try object.encode(Kind.email, forKey: .kind)
          try object.encode(value, forKey: .address)
        case .opaque(let value):
          try object.encode(Kind.opaque, forKey: .kind)
          try object.encode(value, forKey: .value)
        }
      }
    }

    package enum Action: Codable, Sendable {
      case start(callID: ID, line: Line, party: Party)
      case answer(ID)
      case join(ID)
      case end(ID)
      case hold(ID, held: Bool)
      case mute(ID, muted: Bool)
      case video(ID, enabled: Bool)
      case tones(ID, digits: [Digit])

      package enum Digit: String, Codable, Sendable {
        case zero = "0"
        case one = "1"
        case two = "2"
        case three = "3"
        case four = "4"
        case five = "5"
        case six = "6"
        case seven = "7"
        case eight = "8"
        case nine = "9"
        case star = "*"
        case pound = "#"
      }

      private enum Kind: String, Codable { case start, answer, join, end, hold, mute, video, tones }

      package var callID: ID {
        switch self {
        case .start(let id, _, _), .answer(let id), .join(let id), .end(let id),
          .hold(let id, _), .mute(let id, _), .video(let id, _), .tones(let id, _):
          id
        }
      }

      package init(from decoder: any Decoder) throws {
        let object = try Object(decoder)
        let id: ID = try object.decode(.callID)
        let kind = try object.decode(.kind, as: Kind.self)
        switch kind {
        case .start:
          try object.requireOnly(.kind, .callID, .line, .party)
          self = try .start(callID: id, line: object.decode(.line), party: object.decode(.party))
        case .answer, .join, .end:
          try object.requireOnly(.kind, .callID)
          switch kind {
          case .answer: self = .answer(id)
          case .join: self = .join(id)
          default: self = .end(id)
          }
        case .hold:
          try object.requireOnly(.kind, .callID, .held)
          self = try .hold(id, held: object.decode(.held))
        case .mute:
          try object.requireOnly(.kind, .callID, .muted)
          self = try .mute(id, muted: object.decode(.muted))
        case .video:
          try object.requireOnly(.kind, .callID, .enabled)
          self = try .video(id, enabled: object.decode(.enabled))
        case .tones:
          try object.requireOnly(.kind, .callID, .digits)
          let digits = try object.decode(.digits, as: [Digit].self)
          guard !digits.isEmpty else { throw object.invalid("Empty tone sequence") }
          self = .tones(id, digits: digits)
        }
      }

      package func encode(to encoder: any Encoder) throws {
        var object = encoder.container(keyedBy: Key.self)
        try object.encode(callID, forKey: .callID)
        let kind: Kind
        switch self {
        case .start(_, let line, let party):
          kind = .start
          try object.encode(line, forKey: .line)
          try object.encode(party, forKey: .party)
        case .answer: kind = .answer
        case .join: kind = .join
        case .end: kind = .end
        case .hold(_, let held):
          kind = .hold
          try object.encode(held, forKey: .held)
        case .mute(_, let muted):
          kind = .mute
          try object.encode(muted, forKey: .muted)
        case .video(_, let enabled):
          kind = .video
          try object.encode(enabled, forKey: .enabled)
        case .tones(_, let digits):
          kind = .tones
          try object.encode(digits, forKey: .digits)
        }
        try object.encode(kind, forKey: .kind)
      }
    }

    package struct Budgets: Codable, Sendable {
      package struct Answer: Codable, Sendable {
        package let total, claim, reconciliation, settlementReserve: Milliseconds

        package init(from decoder: any Decoder) throws {
          let object = try Object(decoder)
          try object.requireOnly(.total, .claim, .reconciliation, .settlementReserve)
          total = try object.decode(.total)
          claim = try object.decode(.claim)
          reconciliation = try object.decode(.reconciliation)
          settlementReserve = try object.decode(.settlementReserve)
          guard claim.value + reconciliation.value + settlementReserve.value < total.value else {
            throw object.invalid("Answer budget must leave time for media preparation")
          }
        }
      }

      package struct Retention: Codable, Sendable {
        package let lifetime: Milliseconds
        package let terminalRecords: Int32

        package init(from decoder: any Decoder) throws {
          let object = try Object(decoder)
          try object.requireOnly(.lifetime, .terminalRecords)
          lifetime = try object.decode(.lifetime)
          terminalRecords = try object.decode(.terminalRecords)
          guard terminalRecords > 0 else {
            throw object.invalid("Expected a positive terminal record limit")
          }
        }
      }

      package let answer: Answer
      package let placement, incomingRing, outgoingNoAnswer, mediaPreparation: Milliseconds
      package let audioActivation, audioRecovery, connection, reconnection: Milliseconds
      package let retention: Retention?

      package init(from decoder: any Decoder) throws {
        let object = try Object(decoder)
        try object.requireOnly(
          .answer, .placement, .incomingRing, .outgoingNoAnswer, .mediaPreparation,
          .audioActivation, .audioRecovery, .connection, .reconnection, .retention)
        answer = try object.decode(.answer)
        placement = try object.decode(.placement)
        incomingRing = try object.decode(.incomingRing)
        outgoingNoAnswer = try object.decode(.outgoingNoAnswer)
        mediaPreparation = try object.decode(.mediaPreparation)
        audioActivation = try object.decode(.audioActivation)
        audioRecovery = try object.decode(.audioRecovery)
        connection = try object.decode(.connection)
        reconnection = try object.decode(.reconnection)
        retention = try object.optional(.retention)
      }
    }

    // Open coding keys retain unknown names for closed-object validation.
    package struct Key: CodingKey, Hashable, Sendable, ExpressibleByStringLiteral {
      package let stringValue: String
      package var intValue: Int? { nil }

      package init(stringValue: String) { self.stringValue = stringValue }
      package init?(intValue: Int) { return nil }
      package init(stringLiteral value: String) { self.init(stringValue: value) }

      package static let kind: Self = "kind", value: Self = "value", version: Self = "version"
      package static let id: Self = "id", accountID: Self = "accountID", label: Self = "label"
      package static let callID: Self = "callID", remoteID: Self = "remoteID"
      package static let line: Self = "line", party: Self = "party", handle: Self = "handle"
      package static let displayName: Self = "displayName", e164: Self = "e164",
        address: Self = "address"
      package static let held: Self = "held", muted: Self = "muted", enabled: Self = "enabled"
      package static let digits: Self = "digits", reason: Self = "reason", cause: Self = "cause"
      static let receipt: Self = "receipt"
      package static let error: Self = "error", actionID: Self = "actionID", state: Self = "state"
      package static let feature: Self = "feature", permission: Self = "permission"
      package static let stage: Self = "stage", field: Self = "field", platform: Self = "platform"
      package static let code: Self = "code", connectedAt: Self = "connectedAt",
        endedAt: Self = "endedAt"
      package static let direction: Self = "direction", parties: Self = "parties"
      package static let lifecycle: Self = "lifecycle", video: Self = "video", media: Self = "media"
      package static let owner: Self = "owner", preparation: Self = "preparation",
        audio: Self = "audio"
      package static let transport: Self = "transport", answer: Self = "answer",
        total: Self = "total"
      package static let claim: Self = "claim", reconciliation: Self = "reconciliation"
      package static let settlementReserve: Self = "settlementReserve",
        placement: Self = "placement"
      package static let incomingRing: Self = "incomingRing",
        outgoingNoAnswer: Self = "outgoingNoAnswer"
      package static let mediaPreparation: Self = "mediaPreparation",
        audioActivation: Self = "audioActivation"
      package static let audioRecovery: Self = "audioRecovery", connection: Self = "connection"
      package static let reconnection: Self = "reconnection"
      package static let retention: Self = "retention", lifetime: Self = "lifetime"
      package static let terminalRecords: Self = "terminalRecords"
    }

    package struct Object {
      private let container: KeyedDecodingContainer<Key>

      package init(_ decoder: any Decoder) throws {
        container = try decoder.container(keyedBy: Key.self)
      }

      package func requireOnly(_ keys: Key...) throws {
        let unknown = Set(container.allKeys).subtracting(keys).map(\.stringValue).sorted()
        guard unknown.isEmpty else {
          throw invalid("Unexpected fields: \(unknown.joined(separator: ", "))")
        }
      }

      package func decode<T: Decodable>(_ key: Key, as type: T.Type = T.self) throws -> T {
        try container.decode(type, forKey: key)
      }

      internal func payload<T: Decodable>(_ key: Key, as type: T.Type = T.self) throws -> T {
        try requireOnly(.kind, key)
        return try decode(key, as: type)
      }

      package func optional<T: Decodable>(_ key: Key, as type: T.Type = T.self) throws -> T? {
        guard container.contains(key) else { return nil }
        return try decode(key, as: type)
      }

      internal func text(_ key: Key) throws -> String {
        let value: String = try decode(key)
        guard (1...256).contains(value.unicodeScalars.count) else {
          throw invalid("Invalid length for \(key.stringValue)")
        }
        return value
      }

      package func invalid(_ message: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: container.codingPath, debugDescription: message))
      }
    }
  }
#endif

#if SWIFT_PACKAGE
  extension SpecV0.Key {
    package static let configuration: Self = "configuration", steps: Self = "steps"
    package static let outgoingMedia: Self = "outgoingMedia",
      connectionAuthority: Self = "connectionAuthority"
    package static let maximumParticipatingCalls: Self = "maximumParticipatingCalls"
    package static let previewAnsweredElsewhere: Self = "previewAnsweredElsewhere"
    package static let input: Self = "input", expectation: Self = "expectation",
      running: Self = "running"
    package static let javascriptAttached: Self = "javascriptAttached", eventID: Self = "eventID"
    package static let origin: Self = "origin", action: Self = "action", target: Self = "target"
    package static let milliseconds: Self = "milliseconds", callIDs: Self = "callIDs"
    package static let lineID: Self = "lineID", metric: Self = "metric", budgets: Self = "budgets"
  }
#endif
