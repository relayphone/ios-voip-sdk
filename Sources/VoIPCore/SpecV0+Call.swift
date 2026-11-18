#if SWIFT_PACKAGE
  extension SpecV0 {
    package enum State: String, Codable, Sendable {
      case reporting, ringing, previewing, placing, dialing, connecting, connected, reconnecting
      case ending, ended
    }

    package enum Lifecycle: Codable, Sendable {
      case reporting, ringing
      case previewing(PreviewReason)
      case placing, dialing, connecting
      case connected(Timestamp)
      case reconnecting(Timestamp)
      case ending(EndReason)
      case ended(EndReason, Timestamp)

      package var state: State {
        switch self {
        case .reporting: .reporting
        case .ringing: .ringing
        case .previewing: .previewing
        case .placing: .placing
        case .dialing: .dialing
        case .connecting: .connecting
        case .connected: .connected
        case .reconnecting: .reconnecting
        case .ending: .ending
        case .ended: .ended
        }
      }

      package init(from decoder: any Decoder) throws {
        let object = try Object(decoder)
        switch try object.decode(.kind, as: State.self) {
        case .reporting:
          try object.requireOnly(.kind)
          self = .reporting
        case .ringing:
          try object.requireOnly(.kind)
          self = .ringing
        case .placing:
          try object.requireOnly(.kind)
          self = .placing
        case .dialing:
          try object.requireOnly(.kind)
          self = .dialing
        case .connecting:
          try object.requireOnly(.kind)
          self = .connecting
        case .previewing: self = try .previewing(object.payload(.reason))
        case .connected: self = try .connected(object.payload(.connectedAt))
        case .reconnecting: self = try .reconnecting(object.payload(.connectedAt))
        case .ending: self = try .ending(object.payload(.reason))
        case .ended:
          try object.requireOnly(.kind, .reason, .endedAt)
          self = try .ended(object.decode(.reason), object.decode(.endedAt))
        }
      }

      package func encode(to encoder: any Encoder) throws {
        var object = encoder.container(keyedBy: Key.self)
        try object.encode(state, forKey: .kind)
        switch self {
        case .previewing(let reason): try object.encode(reason, forKey: .reason)
        case .connected(let date), .reconnecting(let date):
          try object.encode(date, forKey: .connectedAt)
        case .ending(let reason): try object.encode(reason, forKey: .reason)
        case .ended(let reason, let date):
          try object.encode(reason, forKey: .reason)
          try object.encode(date, forKey: .endedAt)
        default: break
        }
      }
    }

    package struct Timestamp: Codable, Sendable {
      package let rawValue: String

      package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard Self.isValid(value) else {
          throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "Expected a UTC millisecond timestamp")
        }
        rawValue = value
      }

      package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
      }

      private static func isValid(_ value: String) -> Bool {
        guard
          let match = value.wholeMatch(
            of: #/([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})\.[0-9]{3}Z/#
          ), let year = Int(match.1), let month = Int(match.2), let day = Int(match.3),
          let hour = Int(match.4), let minute = Int(match.5), let second = Int(match.6),
          (1...12).contains(month), hour < 24, minute < 60, second < 60
        else { return false }

        let leapYear =
          year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let monthLengths = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...monthLengths[month - 1]).contains(day)
      }
    }

    package struct Call: Codable, Sendable {
      package enum Direction: String, Codable, Sendable { case incoming, outgoing }

      package struct Media: Codable, Sendable {
        package enum Owner: String, Codable, Sendable { case native, application }
        package enum Preparation: String, Codable, Sendable {
          case unprovided, preparing, prepared, released
        }
        package enum Audio: String, Codable, Sendable { case inactive, active }
        package enum Transport: String, Codable, Sendable {
          case disconnected, connecting, connected, reconnecting
        }

        package let owner: Owner
        package let preparation: Preparation
        package let audio: Audio
        package let transport: Transport

        package init(from decoder: any Decoder) throws {
          let object = try Object(decoder)
          try object.requireOnly(.owner, .preparation, .audio, .transport)
          owner = try object.decode(.owner)
          preparation = try object.decode(.preparation)
          audio = try object.decode(.audio)
          transport = try object.decode(.transport)
        }
      }

      package let id: ID
      package let remoteID: ID?
      package let line: Line
      package let direction: Direction
      package let parties: [Party]
      package let lifecycle: Lifecycle
      package let held, muted, video: Bool
      package let media: Media

      package init(from decoder: any Decoder) throws {
        let object = try Object(decoder)
        try object.requireOnly(
          .id, .remoteID, .line, .direction, .parties, .lifecycle, .held, .muted, .video, .media)
        id = try object.decode(.id)
        remoteID = try object.optional(.remoteID)
        line = try object.decode(.line)
        direction = try object.decode(.direction)
        parties = try object.decode(.parties)
        lifecycle = try object.decode(.lifecycle)
        held = try object.decode(.held)
        muted = try object.decode(.muted)
        video = try object.decode(.video)
        media = try object.decode(.media)
        guard !parties.isEmpty else { throw object.invalid("Expected at least one party") }
        switch (direction, lifecycle.state) {
        case (.outgoing, .reporting), (.outgoing, .ringing), (.outgoing, .previewing),
          (.incoming, .dialing):
          throw object.invalid("Call lifecycle conflicts with its direction")
        default: break
        }
      }
    }

    package enum Document: Codable, Sendable {
      case call(Call)
      case action(Action)
      case endReason(EndReason)
      case endResult(EndResult)
      case error(Failure)
      case budgets(Budgets)

      private enum Kind: String, Codable { case call, action, endReason, endResult, error, budgets }

      package init(from decoder: any Decoder) throws {
        let object = try Object(decoder)
        try object.requireOnly(.version, .kind, .value)
        let version: Int = try object.decode(.version)
        guard version == 0 else { throw object.invalid("Unsupported model version") }
        switch try object.decode(.kind, as: Kind.self) {
        case .call: self = try .call(object.decode(.value))
        case .action: self = try .action(object.decode(.value))
        case .endReason: self = try .endReason(object.decode(.value))
        case .endResult: self = try .endResult(object.decode(.value))
        case .error: self = try .error(object.decode(.value))
        case .budgets: self = try .budgets(object.decode(.value))
        }
      }

      package func encode(to encoder: any Encoder) throws {
        var object = encoder.container(keyedBy: Key.self)
        try object.encode(0, forKey: .version)
        func encode(_ kind: Kind, _ value: some Encodable) throws {
          try object.encode(kind, forKey: .kind)
          try object.encode(value, forKey: .value)
        }
        switch self {
        case .call(let value): try encode(.call, value)
        case .action(let value): try encode(.action, value)
        case .endReason(let value): try encode(.endReason, value)
        case .endResult(let value): try encode(.endResult, value)
        case .error(let value): try encode(.error, value)
        case .budgets(let value): try encode(.budgets, value)
        }
      }
    }
  }
#endif
