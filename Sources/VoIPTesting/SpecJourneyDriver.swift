#if SWIFT_PACKAGE
  import Foundation
  package import VoIPCore

  /// Runs version 0 inputs through the native engine and compares its state and port observations.
  @VoIPActor
  package final class SpecJourneyDriver {
    private let clock = TestClock()
    private let framework = FakeCallingFramework()
    private let media = FakeMedia()
    private let authority = ScriptedAuthority()
    private let events = EventLog()
    private let configuration: VoIPConfiguration
    private let outgoingMedia: SpecJourney.Configuration.OutgoingMedia
    private var push = FakePushSource()
    private var engine: SpecEngine?
    private var observedEvents = 0
    private var observedMediaRecords = 0
    private var mediaProvided: Set<CallID> = []
    private var pendingHolds: [Action] = []
    private var endResults: [CallID: EndResult] = [:]
    private var audioActive = false
    private var errors: [(id: CallID, kind: SpecV0.ErrorKind, observed: Bool)] = []

    private init(_ settings: SpecJourney.Configuration) {
      let budgets = settings.budgets
      outgoingMedia = settings.outgoingMedia
      configuration = VoIPConfiguration(
        presentationPolicy: PresentationPolicy(
          previewsCallsAnsweredElsewhere: settings.previewAnsweredElsewhere),
        supportsVideo: true,
        deadlines: Deadlines(
          ring: budgets.incomingRing.duration, placement: budgets.placement.duration,
          mediaPreparation: budgets.mediaPreparation.duration,
          audioActivation: budgets.audioActivation.duration,
          audioRecovery: budgets.audioRecovery.duration,
          connect: budgets.connection.duration, reconnect: budgets.reconnection.duration,
          outgoingNoAnswer: budgets.outgoingNoAnswer.duration),
        retention: .seconds(120),
        outgoingMedia: settings.outgoingMedia == .whenProvided ? .whenProvided : .duringPlacement)
    }

    /// Returns every failed expectation, labeled by its step. Decoding and driver errors throw.
    package static func run(_ journey: SpecJourney) async throws -> [String] {
      let driver = SpecJourneyDriver(journey.configuration)
      defer { driver.engine?.close() }
      var mismatches: [String] = []
      if journey.configuration.connectionAuthority == .nativeMedia {
        mismatches.append("The engine has no native-media connection authority.")
      }
      for (index, step) in journey.steps.enumerated() {
        try Task.checkCancellation()
        let mismatch =
          switch step {
          case .input(let input): try await driver.apply(input)
          case .expect(let expectation): driver.check(expectation)
          }
        if let mismatch { mismatches.append("Step \(index + 1): \(mismatch)") }
      }
      mismatches += driver.errors.filter { !$0.observed }.map {
        "\($0.id.rawValue) returned unexpected action error \($0.kind)."
      }
      return mismatches
    }

    private func start(pending: [VoIPPush] = []) -> SpecEngine {
      if let engine { return engine }
      push = FakePushSource(pending: pending)
      let engine = SpecEngine(
        framework: framework, media: media, push: push, configuration: configuration,
        clock: clock, observe: { [events] in events.values.append($0) })
      self.engine = engine
      return engine
    }

    private func apply(_ input: SpecJourney.Input) async throws -> String? {
      switch input {
      case .process(let running, _):
        // No JavaScript runtime is attached. Placement confirmations are explicit journey inputs.
        if running {
          _ = start()
        } else {
          engine?.close()
          engine = nil
          audioActive = false
          mediaProvided.removeAll()
          pendingHolds.removeAll()
          endResults.removeAll()
        }
      case .incoming(let id, let eventID, _, let party, let deferAdmission):
        let incoming = IncomingCall(id: id.callID, parties: [try party.sdkParty()])
        let delivery = VoIPPush.incoming(incoming, eventID: eventID.eventID)
        if deferAdmission { framework.presentationOutcome = nil }
        if engine == nil {
          _ = start(pending: [delivery])
        } else {
          push.deliver(delivery)
        }
        framework.presentationOutcome = .presented
      case .admitted(let id):
        guard framework.waitingCalls.contains(where: { $0.id == id.callID }) else {
          return "\(id.rawValue) has no pending system admission."
        }
        framework.completeReports(of: id.callID, with: .presented)
      case .admissionFailed(let id, _):
        return "The engine has no per-attempt system failure input for \(id.rawValue)."
      case .authority(let id, let claim, let reconciliation):
        authority.script(id.callID, claim: claim, reconciliation: reconciliation)
      case .latePermit(let id):
        return "\(id.rawValue) has no native authority port to deliver a late permit."
      case .action(.system, .video, _):
        return "The system port has no Video action."
      case .action(.system, .hold, true):
        return "The system port performs a system Hold synchronously."
      case .action(let origin, let action, let deferConfirmation):
        try await perform(action, from: origin, on: start(), deferConfirmation: deferConfirmation)
      case .holdApplied(let id):
        guard let index = pendingHolds.firstIndex(where: { $0.callID == id.callID }) else {
          return "\(id.rawValue) has no Hold request awaiting confirmation."
        }
        framework.perform(pendingHolds.remove(at: index))
      case .placed(let id):
        start().confirmPlaced(id.callID)
      case .provideMedia(let id):
        mediaProvided.insert(id.callID)
        let engine = start()
        // Incoming credentials are consumed by Answer. The current native Answer does not
        // yet have a credential input.
        if outgoingMedia == .whenProvided,
          !engine.calls.contains(where: { $0.id == id.callID && $0.isIncoming })
        {
          try engine.provideMedia(id.callID)
        }
      case .bindRemote(let id, _):
        return "The engine has no remote alias binding for \(id.rawValue)."
      case .connected(let id, let eventID):
        start().receive(.connected, for: id.callID, eventID: eventID.eventID)
      case .remoteEnd(let target, let eventID, let reason):
        guard case .call(let id) = target else {
          return "The engine has no alias-addressed event intake."
        }
        let event: ServerEvent
        switch reason {
        case .remoteEnded: event = .endedRemotely
        case .unanswered: event = .unanswered
        case .answeredElsewhere: event = .answeredElsewhere
        case .declinedElsewhere: event = .declinedElsewhere
        case .failed: return "The engine cannot receive a typed server failure."
        case .localDeclined, .localEnded, .filtered: throw DriverError.invalidRemoteEnd
        }
        start().receive(event, for: id.callID, eventID: eventID.eventID)
      case .advance(let milliseconds):
        try await advance(by: milliseconds.duration)
      }
      await synchronize()
      return checkPreparation()
    }

    private func checkPreparation() -> String? {
      let newRecords = media.records.dropFirst(observedMediaRecords)
      observedMediaRecords = media.records.count
      guard outgoingMedia == .whenProvided else { return nil }
      for case .prepare(let call) in newRecords where !call.isIncoming {
        if !mediaProvided.contains(call.id) {
          return "\(call.id.rawValue) prepared outgoing media before it was provided."
        }
      }
      return nil
    }

    private func synchronize() async {
      guard let engine else { return }
      await engine.synchronize()
      let opened = events.values.dropFirst(observedEvents).contains {
        switch $0 {
        case .performed(.start, _), .performed(.join, _), .performed(.answer, _): true
        default: false
        }
      }
      // The current calling framework activates session audio after the SDK settles a
      // successful Start, Join or Answer. Drive that callback before advancing the clock.
      if audioActive && engine.participating.isEmpty {
        audioActive = false
        framework.send(.audioDeactivated)
      } else if opened && !audioActive {
        audioActive = true
        framework.send(.audioActivated)
      }
      observedEvents = events.values.count
    }

    private func perform(
      _ action: SpecV0.Action, from origin: SpecJourney.Origin, on engine: SpecEngine,
      deferConfirmation: Bool
    ) async throws {
      let id = action.callID.callID
      let request: Action
      switch action {
      case .start(_, _, let party):
        request = .start(OutgoingCall(id: id, parties: [try party.sdkParty()]))
      case .answer: request = .answer(id)
      case .join: request = .join(id)
      case .end: request = .end(id)
      case .hold(_, let held): request = .hold(id, onHold: held)
      case .mute(_, let muted): request = .mute(id, muted: muted)
      case .tones(_, let digits): request = .playTones(id, digits: digits.map(\.rawValue).joined())
      case .video(_, let enabled):
        do {
          try await engine.setVideo(id, enabled: enabled)
        } catch {
          errors.append((id, error.specKind, false))
        }
        return
      }
      if origin == .system {
        framework.perform(request)
      } else {
        let recordStart = framework.records.count
        if deferConfirmation { framework.requestResult = .accept }
        defer { framework.requestResult = .perform }
        do {
          if case .end = request {
            endResults[id] = nil
            endResults[id] = try engine.end(id)
            return
          }
          try await engine.request(request)
          if deferConfirmation,
            framework.records.dropFirst(recordStart).contains(where: {
              if case .request(request, _) = $0 { true } else { false }
            })
          {
            pendingHolds.append(request)
          }
        } catch {
          errors.append((id, error.specKind, false))
        }
      }
    }

    private func advance(by duration: Duration) async throws {
      var remaining = duration
      // Process earlier deadlines before advancing across later ones.
      while let engine, let delay = engine.timeUntilNextDeadline, delay <= remaining {
        try Task.checkCancellation()
        clock.advance(by: delay)
        remaining -= delay
        await synchronize()
      }
      clock.advance(by: remaining)
    }

    private func check(_ expectation: SpecJourney.Expectation) -> String? {
      switch expectation {
      case .call(let expected):
        return checkCall(expected)
      case .count(let id, let metric, let value):
        let count = count(metric, for: id.callID)
        return count == value
          ? nil : "\(id.rawValue) \(metric): expected \(value), observed \(count)."
      case .participating(let ids):
        let actual = engine?.participating.map(\.rawValue) ?? []
        let expected = ids.map(\.rawValue)
        let byBytes: (String, String) -> Bool = { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let paired = zip(actual.sorted(by: byBytes), expected.sorted(by: byBytes))
        return actual.count == expected.count
          && paired.allSatisfy { $0.utf8.elementsEqual($1.utf8) }
          ? nil : "Expected participating \(expected.sorted()), observed \(actual.sorted())."
      case .systemEnd(let id, let cause):
        return systemEnds(for: id.callID).contains(cause)
          ? nil : "\(id.rawValue) has no system End with cause \(cause)."
      case .endResult(let id, let result):
        return endResults[id.callID]?.matches(result) == true
          ? nil : "\(id.rawValue) has no typed End result matching \(result)."
      case .error(let id, let kind, let reason):
        // Legacy errors carry no spec refusal reason.
        guard reason == nil,
          let index = errors.lastIndex(where: { $0.id == id.callID && !$0.observed }),
          errors[index].kind == kind
        else { return "\(id.rawValue) has no matching \(kind) error." }
        errors[index].observed = true
        return nil
      }
    }

    private func checkCall(_ expected: SpecJourney.CallExpectation) -> String? {
      let id = expected.callID.callID
      guard let engine,
        let call = engine.calls.first(where: {
          $0.id.rawValue.utf8.elementsEqual(id.rawValue.utf8)
        })
      else {
        return "No engine state for \(id.rawValue)."
      }
      let actual: SpecJourney.Lifecycle =
        switch engine.phase(for: id) {
        case .reporting: .reporting
        case .placing: .placing
        case .visible: call.specLifecycle
        }
      guard actual == expected.lifecycle else {
        return "\(id.rawValue): expected \(expected.lifecycle), observed \(actual)."
      }
      if expected.lineID != nil || expected.remoteID != nil {
        return "\(id.rawValue) has no observed line or remote alias."
      }
      if let held = expected.held, held != call.isOnHold {
        return "\(id.rawValue): expected held=\(held), observed \(call.isOnHold)."
      }
      if let muted = expected.muted, muted != call.isMuted {
        return "\(id.rawValue): expected muted=\(muted), observed \(call.isMuted)."
      }
      return nil
    }

    private func count(_ metric: SpecJourney.Metric, for id: CallID) -> Int {
      switch metric {
      case .claims: return authority.claims.count { $0 == id }
      case .reconciliations: return authority.reconciliations.count { $0 == id }
      case .claimTimeouts, .permitReleases:
        // The authority port has no engine connection yet.
        return 0
      case .ringingPublications:
        return events.values.count {
          if case .presented(let call) = $0 { call.id == id } else { false }
        }
      case .holdRequests:
        return framework.records.count {
          if case .request(.hold(id, _), _) = $0 { true } else { false }
        }
      case .reports:
        return framework.records.count {
          if case .reportIncoming(let call) = $0 { call.id == id } else { false }
        }
      case .activations:
        return framework.records.count {
          if case .reportOutgoing(id, connected: true) = $0 { true } else { false }
        }
      case .settlements:
        let actions = Set(
          framework.sentEvents.compactMap { event -> ActionID? in
            guard case .perform(let actionID, let action) = event, action.callID == id else {
              return nil
            }
            return actionID
          })
        return framework.records.count {
          switch $0 {
          case .fulfill(let action), .fail(let action): actions.contains(action)
          default: false
          }
        }
      case .placements:
        return events.values.count {
          switch $0 {
          case .startRequested(let call), .joinRequested(let call): call.id == id
          default: false
          }
        }
      case .performedEnds:
        return events.values.count { if case .performed(.end(id), _) = $0 { true } else { false } }
      case .releases:
        return media.lifecycleRecords.count {
          if case .release(let call) = $0 { call.id == id } else { false }
        }
      case .publications:
        var prepared = false
        return media.lifecycleRecords.count { record in
          switch record {
          case .prepare(let call) where call.id == id: prepared = true
          case .release(let call) where call.id == id: prepared = false
          case .activate: return prepared
          default: break
          }
          return false
        }
      }
    }

    private func systemEnds(for id: CallID) -> [SpecJourney.SystemEndCause] {
      framework.records.compactMap {
        guard case .reportEnded(id, let reason) = $0 else { return nil }
        switch reason {
        case .endedRemotely, .answeredElsewhere, .declinedElsewhere: return .remote
        case .unanswered: return .missed
        default: return nil
        }
      }
    }

    private enum DriverError: Error { case invalidRemoteEnd }

    @VoIPActor
    private final class EventLog {
      var values: [CallEvent] = []
    }

    /// The scriptable authority port. The current engine has no hook to call it.
    @VoIPActor
    private final class ScriptedAuthority {
      private var decisions: [CallID: (SpecJourney.Claim, SpecJourney.Reconciliation)] = [:]
      private(set) var claims: [CallID] = []
      private(set) var reconciliations: [CallID] = []

      func script(
        _ id: CallID, claim: SpecJourney.Claim, reconciliation: SpecJourney.Reconciliation
      ) {
        decisions[id] = (claim, reconciliation)
      }

      func claim(_ id: CallID) -> SpecJourney.Claim? {
        claims.append(id)
        return decisions[id]?.0
      }

      func reconcile(_ id: CallID) -> SpecJourney.Reconciliation? {
        reconciliations.append(id)
        return decisions[id]?.1
      }
    }
  }

  extension SpecV0.ID {
    fileprivate var callID: CallID { CallID(rawValue: rawValue) }
    fileprivate var eventID: EventID { EventID(rawValue: rawValue) }
  }

  extension SpecV0.Party {
    fileprivate func sdkParty() throws(HandleError) -> Party {
      let handle: Handle =
        switch self.handle {
        case .phone(let number): try Handle(kind: .phoneNumber, value: number)
        case .email(let address): try Handle(kind: .emailAddress, value: address)
        case .opaque(let value): try Handle(kind: .generic, value: value)
        }
      return Party(handle: handle, displayName: displayName)
    }
  }

  extension ActionError {
    fileprivate var specKind: SpecV0.ErrorKind {
      switch self {
      case .unknownCall: .unknownCall
      case .unsupported: .unsupported
      case .notAllowed: .invalidTransition
      case .refused: .systemFailed
      }
    }
  }

  extension Call {
    fileprivate var specLifecycle: SpecJourney.Lifecycle {
      switch status {
      case .ringing: .ringing
      case .previewing(.answeredElsewhere): .previewing(.answeredElsewhere)
      case .previewing(.policy): .previewing(.policy)
      case .previewing(.filtered(let cause)): .previewing(.filtered(cause.specCause))
      case .dialing: .dialing
      case .connecting: .connecting
      case .connected: .connected
      case .reconnecting: .reconnecting
      case .ended(let reason): .ended(reason.specExpectation)
      }
    }
  }

  extension EndReason {
    fileprivate var specExpectation: SpecJourney.EndExpectation {
      switch self {
      case .localDeclined: .localDeclined
      case .localEnded: .localEnded
      case .endedRemotely: .remoteEnded
      case .unanswered: .unanswered
      case .answeredElsewhere: .answeredElsewhere
      case .declinedElsewhere: .declinedElsewhere
      case .filtered(let cause): .filtered(cause.specCause)
      case .failed(let failure): .failed(failure.specKind)
      }
    }
  }

  extension EndResult {
    fileprivate func matches(_ expected: SpecV0.EndResult) -> Bool {
      switch (self, expected) {
      case (.ended(let actual), .ended(let expected)):
        actual.callID.rawValue.utf8.elementsEqual(expected.callID.rawValue.utf8)
          && actual.actionID.rawValue.uuidString.utf8.elementsEqual(expected.actionID.rawValue.utf8)
          && (expected.reason == .localDeclined
            ? actual.reason == .localDeclined
            : actual.reason == .localEnded)
      case (.alreadyEnded(let actual), .alreadyEnded(let expected)):
        switch (actual.specExpectation, expected) {
        case (.localDeclined, .localDeclined), (.localEnded, .localEnded),
          (.remoteEnded, .remoteEnded), (.unanswered, .unanswered),
          (.answeredElsewhere, .answeredElsewhere), (.declinedElsewhere, .declinedElsewhere):
          true
        case (.filtered(let actual), .filtered(let expected)): actual == expected
        case (.failed(let actual), .failed(let expected)): actual == expected.kind
        default: false
        }
      default: false
      }
    }
  }

  extension CallFailure {
    fileprivate var specKind: SpecV0.ErrorKind {
      switch self {
      case .notPlaced: .placementFailed
      case .media: .mediaFailed
      case .audioActivationTimedOut, .audioRecoveryTimedOut, .connectTimedOut,
        .reconnectTimedOut, .actionTimedOut:
        .deadlineExceeded
      case .refused, .atCapacity, .audioSession, .frameworkReset, .server: .systemFailed
      }
    }
  }

  extension FilterCause {
    fileprivate var specCause: SpecV0.FilterCause {
      switch self {
      case .doNotDisturb: .doNotDisturb
      case .blockList: .blockList
      case .unspecified: .unknown
      }
    }
  }
#endif
