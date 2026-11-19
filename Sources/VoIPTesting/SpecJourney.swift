#if SWIFT_PACKAGE
  package import VoIPCore

  package struct SpecJourney: Decodable, Sendable {
    private enum Version: Int, Decodable { case v0 = 0 }

    private typealias Object = SpecV0.Object
    package typealias ID = SpecV0.ID

    package let id: ID
    package let configuration: Configuration
    package let steps: [Step]

    package init(from decoder: any Decoder) throws {
      let object = try Object(decoder)
      try object.requireOnly(.version, .id, .configuration, .steps)
      let _: Version = try object.decode(.version)
      id = try object.decode(.id)
      configuration = try object.decode(.configuration)
      steps = try object.decode(.steps)
      guard steps.count >= 2,
        steps.contains(where: { if case .expect = $0 { true } else { false } })
      else {
        throw object.invalid("A journey requires at least two steps and one expectation")
      }
    }

    package struct Configuration: Decodable, Sendable {
      package enum OutgoingMedia: String, Decodable, Sendable { case whenProvided, duringPlacement }
      package enum ConnectionAuthority: String, Decodable, Sendable {
        case application, nativeMedia
      }

      package let budgets: SpecV0.Budgets
      package let outgoingMedia: OutgoingMedia
      package let connectionAuthority: ConnectionAuthority
      package let maximumParticipatingCalls: Int
      package let previewAnsweredElsewhere: Bool

      package init(from decoder: any Decoder) throws {
        let object = try Object(decoder)
        try object.requireOnly(
          .budgets, .outgoingMedia, .connectionAuthority, .maximumParticipatingCalls,
          .previewAnsweredElsewhere)
        let maximum: Int = try object.decode(.maximumParticipatingCalls)
        guard maximum == 1 else { throw object.invalid("Expected one participating slot") }
        maximumParticipatingCalls = maximum
        budgets = try object.decode(.budgets)
        outgoingMedia = try object.decode(.outgoingMedia)
        connectionAuthority = try object.decode(.connectionAuthority)
        previewAnsweredElsewhere = try object.decode(.previewAnsweredElsewhere)
      }
    }

    package enum Step: Decodable, Sendable {
      private enum Kind: String, Decodable { case input, expect }

      case input(Input)
      case expect(Expectation)

      package init(from decoder: any Decoder) throws {
        let object = try Object(decoder)
        switch try object.decode(.kind, as: Kind.self) {
        case .input:
          try object.requireOnly(.kind, .input)
          self = .input(try object.decode(.input))
        case .expect:
          try object.requireOnly(.kind, .expectation)
          self = .expect(try object.decode(.expectation))
        }
      }
    }

    package enum Claim: Decodable, Sendable {
      private enum Kind: String, Decodable { case allow, refuse, timeout }

      case allow
      case refuse(SpecV0.Refusal)
      case timeout

      package init(from decoder: any Decoder) throws {
        let object = try Object(decoder)
        let kind: Kind = try object.decode(.kind)
        if kind == .refuse {
          try object.requireOnly(.kind, .reason)
          self = .refuse(try object.decode(.reason))
        } else {
          try object.requireOnly(.kind)
          self = kind == .allow ? .allow : .timeout
        }
      }
    }

    package enum Reconciliation: Decodable, Sendable {
      private enum Kind: String, Decodable { case allow, refuse, unknown }

      case allow
      case refuse(SpecV0.Refusal)
      case unknown

      package init(from decoder: any Decoder) throws {
        let object = try Object(decoder)
        let kind: Kind = try object.decode(.kind)
        if kind == .refuse {
          try object.requireOnly(.kind, .reason)
          self = .refuse(try object.decode(.reason))
        } else {
          try object.requireOnly(.kind)
          self = kind == .allow ? .allow : .unknown
        }
      }
    }

    package enum Target: Decodable, Sendable {
      private enum Kind: String, Decodable { case call, remote }

      case call(ID)
      case remote(ID)

      package init(from decoder: any Decoder) throws {
        let object = try Object(decoder)
        try object.requireOnly(.kind, .id)
        let id: ID = try object.decode(.id)
        switch try object.decode(.kind, as: Kind.self) {
        case .call: self = .call(id)
        case .remote: self = .remote(id)
        }
      }
    }

    package enum Origin: String, Decodable, Sendable { case app, system }

    package enum Input: Decodable, Sendable {
      private enum Kind: String, Decodable {
        case process, incoming, authority, action, placed, provideMedia, bindRemote, connected
        case remoteEnd, advance, admitted, admissionFailed, latePermit, holdApplied
        case startAdmitted, startFailed
      }

      case process(running: Bool, javascriptAttached: Bool)
      case incoming(
        callID: ID, eventID: ID, line: SpecV0.Line, party: SpecV0.Party, deferAdmission: Bool)
      case authority(callID: ID, claim: Claim, reconciliation: Reconciliation)
      case action(origin: Origin, action: SpecV0.Action, deferConfirmation: Bool)
      case placed(callID: ID, deferStartAdmission: Bool)
      case startAdmitted(callID: ID, stale: Bool)
      case startFailed(callID: ID, failure: SpecV0.Failure.SystemCause)
      case provideMedia(callID: ID)
      case admitted(callID: ID)
      case admissionFailed(callID: ID, failure: SpecV0.Failure.SystemCause)
      case latePermit(callID: ID)
      case holdApplied(callID: ID)
      case bindRemote(callID: ID, remoteID: ID)
      case connected(callID: ID, eventID: ID)
      case remoteEnd(target: Target, eventID: ID, reason: SpecV0.EndReason)
      case advance(milliseconds: SpecV0.Milliseconds)

      package init(from decoder: any Decoder) throws {
        let object = try Object(decoder)
        switch try object.decode(.kind, as: Kind.self) {
        case .process:
          try object.requireOnly(.kind, .running, .javascriptAttached)
          self = .process(
            running: try object.decode(.running),
            javascriptAttached: try object.decode(.javascriptAttached))
        case .incoming:
          try object.requireOnly(.kind, .callID, .eventID, .line, .party, .deferAdmission)
          self = .incoming(
            callID: try object.decode(.callID), eventID: try object.decode(.eventID),
            line: try object.decode(.line), party: try object.decode(.party),
            deferAdmission: try object.flag(.deferAdmission))
        case .authority:
          try object.requireOnly(.kind, .callID, .claim, .reconciliation)
          self = .authority(
            callID: try object.decode(.callID), claim: try object.decode(.claim),
            reconciliation: try object.decode(.reconciliation))
        case .action:
          try object.requireOnly(.kind, .origin, .action, .deferConfirmation)
          let action: SpecV0.Action = try object.decode(.action)
          let deferConfirmation = try object.flag(.deferConfirmation)
          if deferConfirmation {
            guard case .hold = action else {
              throw object.invalid("Only Hold supports deferred confirmation")
            }
          }
          self = .action(
            origin: try object.decode(.origin), action: action, deferConfirmation: deferConfirmation
          )
        case .placed:
          try object.requireOnly(.kind, .callID, .deferStartAdmission)
          self = .placed(
            callID: try object.decode(.callID),
            deferStartAdmission: try object.flag(.deferStartAdmission))
        case .startAdmitted:
          try object.requireOnly(.kind, .callID, .stale)
          self = .startAdmitted(callID: try object.decode(.callID), stale: try object.flag(.stale))
        case .startFailed:
          try object.requireOnly(.kind, .callID, .failure)
          let failure: SpecV0.Failure.SystemCause = try object.decode(.failure)
          guard failure.kind == .start else { throw object.invalid("Expected a Start failure") }
          self = .startFailed(callID: try object.decode(.callID), failure: failure)
        case .provideMedia:
          try object.requireOnly(.kind, .callID)
          self = .provideMedia(callID: try object.decode(.callID))
        case .admitted:
          try object.requireOnly(.kind, .callID)
          self = .admitted(callID: try object.decode(.callID))
        case .admissionFailed:
          try object.requireOnly(.kind, .callID, .failure)
          let failure: SpecV0.Failure.SystemCause = try object.decode(.failure)
          guard failure.kind == .admission else {
            throw object.invalid("Expected an admission failure")
          }
          self = .admissionFailed(callID: try object.decode(.callID), failure: failure)
        case .latePermit:
          try object.requireOnly(.kind, .callID)
          self = .latePermit(callID: try object.decode(.callID))
        case .holdApplied:
          try object.requireOnly(.kind, .callID)
          self = .holdApplied(callID: try object.decode(.callID))
        case .bindRemote:
          try object.requireOnly(.kind, .callID, .remoteID)
          self = .bindRemote(
            callID: try object.decode(.callID), remoteID: try object.decode(.remoteID))
        case .connected:
          try object.requireOnly(.kind, .callID, .eventID)
          self = .connected(
            callID: try object.decode(.callID), eventID: try object.decode(.eventID))
        case .remoteEnd:
          try object.requireOnly(.kind, .target, .eventID, .reason)
          let reason: SpecV0.EndReason = try object.decode(.reason)
          switch reason {
          case .localDeclined, .localEnded, .filtered:
            throw object.invalid("Invalid remote end reason")
          case .remoteEnded, .unanswered, .answeredElsewhere, .declinedElsewhere, .failed:
            self = .remoteEnd(
              target: try object.decode(.target), eventID: try object.decode(.eventID),
              reason: reason
            )
          }
        case .advance:
          try object.requireOnly(.kind, .milliseconds)
          self = .advance(milliseconds: try object.decode(.milliseconds))
        }
      }
    }

    package enum EndExpectation: Decodable, Equatable, Sendable {
      private enum Kind: String, Decodable {
        case localDeclined, localEnded, remoteEnded, unanswered, answeredElsewhere,
          declinedElsewhere
        case filtered, failed
      }

      case localDeclined, localEnded, remoteEnded, unanswered, answeredElsewhere, declinedElsewhere
      case filtered(SpecV0.FilterCause)
      case failed(SpecV0.ErrorKind)

      package init(from decoder: any Decoder) throws {
        let object = try Object(decoder)
        let kind: Kind = try object.decode(.kind)
        if kind != .filtered && kind != .failed {
          try object.requireOnly(.kind)
        }
        switch kind {
        case .localDeclined: self = .localDeclined
        case .localEnded: self = .localEnded
        case .remoteEnded: self = .remoteEnded
        case .unanswered: self = .unanswered
        case .answeredElsewhere: self = .answeredElsewhere
        case .declinedElsewhere: self = .declinedElsewhere
        case .filtered:
          try object.requireOnly(.kind, .cause)
          self = .filtered(try object.decode(.cause))
        case .failed:
          try object.requireOnly(.kind, .error)
          self = .failed(try object.decode(.error))
        }
      }
    }

    package enum Lifecycle: Decodable, Equatable, Sendable {
      private enum Kind: String, Decodable {
        case reporting, ringing, previewing, placing, dialing, connecting, connected, reconnecting
        case ending, ended
      }

      case reporting, ringing, placing, dialing, connecting, connected, reconnecting
      case previewing(SpecV0.PreviewReason)
      case ending(EndExpectation)
      case ended(EndExpectation)

      package init(from decoder: any Decoder) throws {
        let object = try Object(decoder)
        let kind: Kind = try object.decode(.kind)
        if kind != .previewing && kind != .ending && kind != .ended {
          try object.requireOnly(.kind)
        }
        switch kind {
        case .reporting: self = .reporting
        case .ringing: self = .ringing
        case .placing: self = .placing
        case .dialing: self = .dialing
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .reconnecting: self = .reconnecting
        case .previewing:
          try object.requireOnly(.kind, .reason)
          self = .previewing(try object.decode(.reason))
        case .ending, .ended:
          try object.requireOnly(.kind, .reason)
          let reason: EndExpectation = try object.decode(.reason)
          self = kind == .ending ? .ending(reason) : .ended(reason)
        }
      }
    }

    package enum Metric: String, Decodable, Hashable, Sendable {
      case claims, reconciliations, settlements, publications, activations, reports, placements
      case performedEnds, releases, claimTimeouts, permitReleases, ringingPublications, holdRequests
    }

    package enum SystemEndCause: String, Decodable, Sendable {
      case local, remote, missed, rejected
    }

    package struct CallExpectation: Sendable {
      package let callID: ID
      package let lifecycle: Lifecycle
      package let lineID: ID?
      package let remoteID: ID?
      package let held: Bool?
      package let muted: Bool?
    }

    package enum Expectation: Decodable, Sendable {
      private enum Kind: String, Decodable {
        case call, count, participating, systemEnd, error, endResult
      }

      case call(CallExpectation)
      case count(callID: ID, metric: Metric, value: Int)
      case participating(callIDs: [ID])
      case systemEnd(callID: ID, cause: SystemEndCause)
      case error(callID: ID, error: SpecV0.ErrorKind, reason: SpecV0.Refusal?)
      case endResult(callID: ID, result: SpecV0.EndResult)

      package init(from decoder: any Decoder) throws {
        let object = try Object(decoder)
        switch try object.decode(.kind, as: Kind.self) {
        case .call:
          try object.requireOnly(.kind, .callID, .lifecycle, .lineID, .remoteID, .held, .muted)
          self = .call(
            CallExpectation(
              callID: try object.decode(.callID), lifecycle: try object.decode(.lifecycle),
              lineID: try object.optional(.lineID), remoteID: try object.optional(.remoteID),
              held: try object.optional(.held), muted: try object.optional(.muted)))
        case .count:
          try object.requireOnly(.kind, .callID, .metric, .value)
          let value: Int = try object.decode(.value)
          guard (0...9_007_199_254_740_991).contains(value) else {
            throw object.invalid("Expected a nonnegative safe integer count")
          }
          self = .count(
            callID: try object.decode(.callID), metric: try object.decode(.metric), value: value)
        case .participating:
          try object.requireOnly(.kind, .callIDs)
          self = .participating(callIDs: try object.decode(.callIDs))
        case .systemEnd:
          try object.requireOnly(.kind, .callID, .cause)
          self = .systemEnd(callID: try object.decode(.callID), cause: try object.decode(.cause))
        case .error:
          let error: SpecV0.ErrorKind = try object.decode(.error)
          if error == .refused {
            try object.requireOnly(.kind, .callID, .error, .reason)
          } else {
            try object.requireOnly(.kind, .callID, .error)
          }
          self = .error(
            callID: try object.decode(.callID), error: error, reason: try object.optional(.reason))
        case .endResult:
          try object.requireOnly(.kind, .callID, .result)
          self = .endResult(callID: try object.decode(.callID), result: try object.decode(.result))
        }
      }
    }
  }

  extension SpecV0.Key {
    fileprivate static let deferAdmission: Self = "deferAdmission"
    fileprivate static let deferStartAdmission: Self = "deferStartAdmission"
    fileprivate static let deferConfirmation: Self = "deferConfirmation"
    fileprivate static let stale: Self = "stale"
    fileprivate static let failure: Self = "failure"
    fileprivate static let result: Self = "result"
  }

  extension SpecV0.Object {
    fileprivate func flag(_ key: SpecV0.Key) throws -> Bool {
      guard let value: Bool = try optional(key) else { return false }
      guard value else { throw invalid("\(key.stringValue) must be true when present") }
      return value
    }
  }
#endif
