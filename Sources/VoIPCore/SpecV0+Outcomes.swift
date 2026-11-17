#if SWIFT_PACKAGE
  extension SpecV0 {
    package enum FilterCause: String, Codable, Sendable {
      case doNotDisturb, blockList, unknown
    }

    package enum Refusal: String, Codable, Sendable {
      case answeredElsewhere, declinedElsewhere, notAllowed

      package init(from decoder: any Decoder) throws {
        let object = try Object(decoder)
        try object.requireOnly(.kind)
        let kind: String = try object.decode(.kind)
        guard let reason = Self(rawValue: kind) else { throw object.invalid("Unknown refusal") }
        self = reason
      }

      package func encode(to encoder: any Encoder) throws {
        var object = encoder.container(keyedBy: Key.self)
        try object.encode(rawValue, forKey: .kind)
      }
    }

    package enum PreviewReason: Codable, Equatable, Sendable {
      case filtered(FilterCause)
      case answeredElsewhere, policy

      private enum Kind: String, Codable { case filtered, answeredElsewhere, policy }

      package init(from decoder: any Decoder) throws {
        let object = try Object(decoder)
        let kind = try object.decode(.kind, as: Kind.self)
        if kind == .filtered {
          try object.requireOnly(.kind, .cause)
          self = try .filtered(object.decode(.cause))
        } else {
          try object.requireOnly(.kind)
          self = kind == .answeredElsewhere ? .answeredElsewhere : .policy
        }
      }

      package func encode(to encoder: any Encoder) throws {
        var object = encoder.container(keyedBy: Key.self)
        let kind: Kind
        switch self {
        case .filtered(let cause):
          kind = .filtered
          try object.encode(cause, forKey: .cause)
        case .answeredElsewhere: kind = .answeredElsewhere
        case .policy: kind = .policy
        }
        try object.encode(kind, forKey: .kind)
      }
    }

    package enum ErrorKind: String, Codable, Sendable {
      case unknownCall, invalidTransition, unsupported, permissionRequired, refused
      case authorityUnavailable, claimTimedOut, placementFailed, deadlineExceeded, mediaFailed
      case remoteIdentityConflict, invalidConfiguration, systemFailed, bridgeUnavailable
    }

    package enum Failure: Codable, Sendable {
      case unknownCall(ID)
      case invalidTransition(State)
      case unsupported(Feature)
      case permissionRequired(Permission)
      case refused(Refusal)
      case authorityUnavailable(AuthorityCause)
      case claimTimedOut(ID)
      case placementFailed(PlacementCause)
      case deadlineExceeded(DeadlineStage)
      case mediaFailed(MediaStage, MediaCause)
      case remoteIdentityConflict(ID)
      case invalidConfiguration(BudgetField)
      case systemFailed(SystemCause)
      case bridgeUnavailable

      package enum Feature: String, Codable, Sendable { case hold, video, tones, preview, merge }
      package enum Permission: String, Codable, Sendable { case microphone, camera }
      package enum AuthorityCause: String, Codable, Sendable {
        case credentialsUnavailable, network, invalidResponse
      }
      package enum PlacementCause: String, Codable, Sendable { case cancelled, handlerFailed }
      package enum DeadlineStage: String, Codable, Sendable {
        case placement, claim, reconciliation, mediaPreparation, audioActivation, connection
        case reconnection, systemAction, noAnswer
      }
      package enum MediaStage: String, Codable, Sendable { case prepare, activate, release }
      package enum MediaCause: String, Codable, Sendable { case transport, permission, timeout }
      package enum BudgetField: String, Codable, Sendable {
        case answer, placement, incomingRing, outgoingNoAnswer, mediaPreparation, audioActivation
        case audioRecovery, connection, reconnection, retention
      }

      package struct SystemCause: Codable, Sendable {
        package enum Platform: String, Codable, Sendable { case ios, android }
        package enum Kind: String, Codable, Sendable {
          case admission, action, removal, reset, audio
        }

        package let platform: Platform
        package let kind: Kind
        package let code: Int32?

        package init(from decoder: any Decoder) throws {
          let object = try Object(decoder)
          try object.requireOnly(.platform, .kind, .code)
          platform = try object.decode(.platform)
          kind = try object.decode(.kind)
          code = try object.optional(.code)
        }
      }

      package var kind: ErrorKind {
        switch self {
        case .unknownCall: .unknownCall
        case .invalidTransition: .invalidTransition
        case .unsupported: .unsupported
        case .permissionRequired: .permissionRequired
        case .refused: .refused
        case .authorityUnavailable: .authorityUnavailable
        case .claimTimedOut: .claimTimedOut
        case .placementFailed: .placementFailed
        case .deadlineExceeded: .deadlineExceeded
        case .mediaFailed: .mediaFailed
        case .remoteIdentityConflict: .remoteIdentityConflict
        case .invalidConfiguration: .invalidConfiguration
        case .systemFailed: .systemFailed
        case .bridgeUnavailable: .bridgeUnavailable
        }
      }

      package init(from decoder: any Decoder) throws {
        let object = try Object(decoder)
        switch try object.decode(.kind, as: ErrorKind.self) {
        case .unknownCall: self = try .unknownCall(object.payload(.callID))
        case .invalidTransition: self = try .invalidTransition(object.payload(.state))
        case .unsupported: self = try .unsupported(object.payload(.feature))
        case .permissionRequired: self = try .permissionRequired(object.payload(.permission))
        case .refused: self = try .refused(object.payload(.reason))
        case .authorityUnavailable: self = try .authorityUnavailable(object.payload(.cause))
        case .claimTimedOut: self = try .claimTimedOut(object.payload(.actionID))
        case .placementFailed: self = try .placementFailed(object.payload(.cause))
        case .deadlineExceeded: self = try .deadlineExceeded(object.payload(.stage))
        case .mediaFailed:
          try object.requireOnly(.kind, .stage, .cause)
          self = try .mediaFailed(object.decode(.stage), object.decode(.cause))
        case .remoteIdentityConflict: self = try .remoteIdentityConflict(object.payload(.remoteID))
        case .invalidConfiguration: self = try .invalidConfiguration(object.payload(.field))
        case .systemFailed: self = try .systemFailed(object.payload(.cause))
        case .bridgeUnavailable:
          try object.requireOnly(.kind)
          self = .bridgeUnavailable
        }
      }

      package func encode(to encoder: any Encoder) throws {
        var object = encoder.container(keyedBy: Key.self)
        try object.encode(kind, forKey: .kind)
        switch self {
        case .unknownCall(let value): try object.encode(value, forKey: .callID)
        case .invalidTransition(let value): try object.encode(value, forKey: .state)
        case .unsupported(let value): try object.encode(value, forKey: .feature)
        case .permissionRequired(let value): try object.encode(value, forKey: .permission)
        case .refused(let value): try object.encode(value, forKey: .reason)
        case .authorityUnavailable(let value): try object.encode(value, forKey: .cause)
        case .claimTimedOut(let value): try object.encode(value, forKey: .actionID)
        case .placementFailed(let value): try object.encode(value, forKey: .cause)
        case .deadlineExceeded(let value): try object.encode(value, forKey: .stage)
        case .mediaFailed(let stage, let cause):
          try object.encode(stage, forKey: .stage)
          try object.encode(cause, forKey: .cause)
        case .remoteIdentityConflict(let value): try object.encode(value, forKey: .remoteID)
        case .invalidConfiguration(let value): try object.encode(value, forKey: .field)
        case .systemFailed(let value): try object.encode(value, forKey: .cause)
        case .bridgeUnavailable: break
        }
      }
    }

    package enum EndResult: Codable, Sendable {
      case ended(Receipt)
      case alreadyEnded(EndReason)

      package enum LocalReason: String, Codable, Sendable {
        case localDeclined, localEnded

        package init(from decoder: any Decoder) throws {
          let object = try Object(decoder)
          try object.requireOnly(.kind)
          let kind: String = try object.decode(.kind)
          guard let reason = Self(rawValue: kind) else {
            throw object.invalid("An End receipt requires a local reason")
          }
          self = reason
        }

        package func encode(to encoder: any Encoder) throws {
          var object = encoder.container(keyedBy: Key.self)
          try object.encode(rawValue, forKey: .kind)
        }
      }

      package struct Receipt: Codable, Equatable, Sendable {
        package let callID, actionID: ID
        package let reason: LocalReason

        package init(from decoder: any Decoder) throws {
          let object = try Object(decoder)
          try object.requireOnly(.callID, .actionID, .reason)
          callID = try object.decode(.callID)
          actionID = try object.decode(.actionID)
          reason = try object.decode(.reason)
        }
      }

      private enum Kind: String, Codable { case ended, alreadyEnded }

      package init(from decoder: any Decoder) throws {
        let object = try Object(decoder)
        switch try object.decode(.kind, as: Kind.self) {
        case .ended: self = try .ended(object.payload(.receipt))
        case .alreadyEnded: self = try .alreadyEnded(object.payload(.reason))
        }
      }

      package func encode(to encoder: any Encoder) throws {
        var object = encoder.container(keyedBy: Key.self)
        switch self {
        case .ended(let receipt):
          try object.encode(Kind.ended, forKey: .kind)
          try object.encode(receipt, forKey: .receipt)
        case .alreadyEnded(let reason):
          try object.encode(Kind.alreadyEnded, forKey: .kind)
          try object.encode(reason, forKey: .reason)
        }
      }
    }

    package enum EndReason: Codable, Sendable {
      case localDeclined, localEnded, remoteEnded, unanswered, answeredElsewhere, declinedElsewhere
      case filtered(FilterCause)
      case failed(Failure)

      package enum Kind: String, Codable, Sendable {
        case localDeclined, localEnded, remoteEnded, unanswered, answeredElsewhere,
          declinedElsewhere
        case filtered, failed
      }

      package var kind: Kind {
        switch self {
        case .localDeclined: .localDeclined
        case .localEnded: .localEnded
        case .remoteEnded: .remoteEnded
        case .unanswered: .unanswered
        case .answeredElsewhere: .answeredElsewhere
        case .declinedElsewhere: .declinedElsewhere
        case .filtered: .filtered
        case .failed: .failed
        }
      }

      package init(from decoder: any Decoder) throws {
        let object = try Object(decoder)
        let kind = try object.decode(.kind, as: Kind.self)
        switch kind {
        case .filtered: self = try .filtered(object.payload(.cause))
        case .failed:
          let error = try object.payload(.error, as: Failure.self)
          if case .refused(let reason) = error, reason != .notAllowed {
            throw object.invalid("An elsewhere refusal must use its own end reason")
          }
          self = .failed(error)
        case .localDeclined, .localEnded, .remoteEnded, .unanswered, .answeredElsewhere,
          .declinedElsewhere:
          try object.requireOnly(.kind)
          switch kind {
          case .localDeclined: self = .localDeclined
          case .localEnded: self = .localEnded
          case .remoteEnded: self = .remoteEnded
          case .unanswered: self = .unanswered
          case .answeredElsewhere: self = .answeredElsewhere
          case .declinedElsewhere: self = .declinedElsewhere
          case .filtered, .failed: preconditionFailure("Handled above")
          }
        }
      }

      package func encode(to encoder: any Encoder) throws {
        var object = encoder.container(keyedBy: Key.self)
        try object.encode(kind, forKey: .kind)
        switch self {
        case .filtered(let cause): try object.encode(cause, forKey: .cause)
        case .failed(let error): try object.encode(error, forKey: .error)
        default: break
        }
      }
    }
  }
#endif
