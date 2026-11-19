#if SWIFT_PACKAGE
  import Foundation
  package import VoIPCore

  /// Runs version 0 inputs through the native engine and compares its state and port observations.
  @VoIPActor
  package final class SpecJourneyDriver {
    private let clock = TestClock()
    private let framework = FakeCallingFramework()
    private var admittedReports: [CallID: @VoIPActor (PresentationOutcome) -> Void] = [:]
    private let media = FakeMedia()
    private let authority: ScriptedAuthority
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
    private var actionCount = 0
    private var endActionIDs: [ActionID: String] = [:]
    private var startSettlements: [CallID: Int] = [:]
    private var audioActive = false
    private var errors: [ObservedError] = []
    private var claimTasks: [CallID: Task<Void, Never>] = [:]

    private struct ObservedError {
      let id: CallID
      let kind: SpecV0.ErrorKind
      var reason: SpecV0.Refusal?
      var observed = false
      var isNativeObservation = false
    }

    private init(_ settings: SpecJourney.Configuration) {
      authority = ScriptedAuthority(clock: clock)
      outgoingMedia = settings.outgoingMedia
      configuration = settings.sdkConfiguration
    }

    /// Returns every failed expectation, labeled by its step. Decoding and driver errors throw.
    package static func run(_ journey: SpecJourney) async throws -> [String] {
      let driver = SpecJourneyDriver(journey.configuration)
      defer {
        driver.engine?.close()
        driver.authority.finishClaims()
      }
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
      mismatches += driver.errors.filter { !$0.observed && !$0.isNativeObservation }.map {
        "\($0.id.rawValue) returned unexpected action error \($0.kind)."
      }
      return mismatches
    }

    private func start(pending: [VoIPPush] = []) -> SpecEngine {
      if let engine { return engine }
      push = FakePushSource(pending: pending)
      let engine = SpecEngine(
        framework: framework, media: media, push: push, configuration: configuration,
        clock: clock, authority: authority, observe: { [events] in events.values.append($0) })
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
          authority.finishClaims()
          claimTasks.removeAll()
          endResults.removeAll()
          admittedReports.removeAll()
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
        guard let complete = framework.takeReportCompletion(of: id.callID) else {
          return "\(id.rawValue) has no pending system admission."
        }
        admittedReports[id.callID] = complete
        complete(.presented)
      case .admissionFailed(let id, let cause):
        guard
          let complete = framework.takeReportCompletion(of: id.callID)
            ?? admittedReports.removeValue(forKey: id.callID)
        else { return "\(id.rawValue) has no system admission to refuse." }
        let failure = SystemFailure(
          platform: cause.platform == .ios ? .ios : .android, operation: .admission,
          diagnostic: cause.code.map(SystemFailure.Diagnostic.code))
        complete(.refused(.systemFailed(failure)))
      case .authority(let id, let claim, let reconciliation):
        authority.script(id.callID, claim: claim, reconciliation: reconciliation)
      case .latePermit(let id):
        guard authority.deliverLatePermit(id.callID) else {
          return "\(id.rawValue) has no outstanding claim."
        }
        await claimTasks.removeValue(forKey: id.callID)?.value
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
      case .placed(let id, let deferStartAdmission):
        if deferStartAdmission { framework.requestResult = .accept }
        start().confirmPlaced(id.callID)
        await synchronize()
        framework.requestResult = .perform
      case .startAdmitted(let id, let stale):
        if stale {
          guard
            let outgoing = framework.records.reversed().compactMap({ record -> OutgoingCall? in
              if case .request(.start(let outgoing), _) = record, outgoing.id == id.callID {
                return outgoing
              }
              return nil
            }).first
          else { return "\(id.rawValue) has no native Start to replay." }
          start().replayStaleStartAdmission(outgoing, action: ActionID(rawValue: UUID()))
        } else {
          guard let complete = framework.takeStartCompletion(of: id.callID) else {
            return "\(id.rawValue) has no pending native Start."
          }
          complete(.success(()))
        }
      case .startFailed(let id, let failure):
        guard let complete = framework.takeStartCompletion(of: id.callID) else {
          return "\(id.rawValue) has no pending native Start."
        }
        framework.platform = failure.platform == .ios ? .ios : .android
        let detail = failure.code.map { FrameworkError(domain: "spec.start", code: Int($0)) }
        complete(.failure(.refused(detail)))
        framework.platform = .ios
      case .provideMedia(let id):
        mediaProvided.insert(id.callID)
        let engine = start()
        // Incoming credentials are held by the media port for authorized Answer.
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
      let newEvents = Array(events.values.dropFirst(observedEvents))
      observedEvents += newEvents.count
      for event in newEvents {
        switch event {
        case .answerClaimTimedOut(let call, _):
          if let task = engine.answerTask(call.id, reconciling: true) {
            await authority.waitForReconciliation(call.id)
            if authority.reconcilesImmediately(call.id) { await task.value }
          }
        case .answerFailed(let call, _, let failure):
          switch failure {
          case .refused(let reason):
            errors.append(
              .init(
                id: call.id, kind: .refused, reason: SpecV0.Refusal(reason),
                isNativeObservation: true))
          case .claimTimedOut:
            errors.append(.init(id: call.id, kind: .claimTimedOut, isNativeObservation: true))
          case .unavailable:
            errors.append(
              .init(id: call.id, kind: .authorityUnavailable, isNativeObservation: true))
          case .invalidBudget:
            errors.append(
              .init(id: call.id, kind: .invalidConfiguration, isNativeObservation: true))
          }
        default: break
        }
      }
      let opened = newEvents.contains {
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
      if observedEvents < events.values.count { await synchronize() }
    }

    private func perform(
      _ action: SpecV0.Action, from origin: SpecJourney.Origin, on engine: SpecEngine,
      deferConfirmation: Bool
    ) async throws {
      let id = action.callID.callID
      actionCount += 1
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
          errors.append(.init(id: id, kind: error.specKind, reason: error.specRefusal))
        }
        return
      }
      if origin == .system {
        framework.perform(request)
        if case .answer = request, let task = engine.answerTask(id) {
          if authority.claimsImmediately(id) {
            await task.value
          } else {
            claimTasks[id] = task
            await authority.waitForClaim(id)
          }
        }
      } else if case .start(let outgoing) = request {
        engine.start(outgoing) { [weak self] result in
          self?.startSettlements[id, default: 0] += 1
          if case .failure(let error) = result {
            self?.errors.append(.init(id: id, kind: error.specKind, reason: error.specRefusal))
          }
        }
      } else {
        let recordStart = framework.records.count
        if deferConfirmation { framework.requestResult = .accept }
        defer { framework.requestResult = .perform }
        do {
          if case .end = request {
            endResults[id] = nil
            let actionID = ActionID(rawValue: UUID())
            endActionIDs[actionID] = "request-\(actionCount)"
            endResults[id] = try engine.end(id, actionID: actionID)
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
          errors.append(.init(id: id, kind: error.specKind, reason: error.specRefusal))
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
        return endResults[id.callID]?.matches(result, actionIDs: endActionIDs) == true
          ? nil : "\(id.rawValue) has no typed End result matching \(result)."
      case .error(let id, let kind, let reason):
        guard let index = errors.lastIndex(where: { $0.id == id.callID && !$0.observed }),
          errors[index].kind == kind, reason == nil || errors[index].reason == reason
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
      case .claimTimeouts:
        return events.values.count {
          if case .answerClaimTimedOut(let call, _) = $0 { call.id == id } else { false }
        }
      case .permitReleases: return authority.releases.count { $0 == id }
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
            if case .start = action, startSettlements[id] != nil { return nil }
            return actionID
          })
        return startSettlements[id, default: 0]
          + framework.records.count {
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
        case .failed(.answerAuthorization(.refused(.notAllowed))): return .rejected
        default: return nil
        }
      }
    }

    private enum DriverError: Error { case invalidRemoteEnd }

    @VoIPActor
    private final class EventLog {
      var values: [CallEvent] = []
    }

    @VoIPActor
    private final class ScriptedAuthority: AnswerAuthority {
      private let clock: TestClock
      private var decisions: [CallID: (SpecJourney.Claim, SpecJourney.Reconciliation)] = [:]
      private var pendingClaims: [CallID: CheckedContinuation<AnswerDecision, Never>] = [:]
      private var claimWaiters: [CallID: CheckedContinuation<Void, Never>] = [:]
      private var reconciliationWaiters: [CallID: CheckedContinuation<Void, Never>] = [:]
      private(set) var claims: [CallID] = []
      private(set) var reconciliations: [CallID] = []
      private(set) var releases: [CallID] = []

      init(clock: TestClock) { self.clock = clock }

      func script(
        _ id: CallID, claim: SpecJourney.Claim, reconciliation: SpecJourney.Reconciliation
      ) {
        decisions[id] = (claim, reconciliation)
      }

      func claimsImmediately(_ id: CallID) -> Bool {
        if case .timeout = decisions[id]?.0 { false } else { true }
      }

      func reconcilesImmediately(_ id: CallID) -> Bool {
        switch decisions[id]?.1 {
        case .allow, .refuse: true
        default: false
        }
      }

      func claim(_ request: AnswerRequest) async -> AnswerDecision {
        let id = request.call.id
        claims.append(id)
        switch decisions[id]?.0 {
        case .refuse(let reason): return .refuse(reason.native)
        case .allow, nil: return .allow(permit(id))
        case .timeout:
          return await withCheckedContinuation { continuation in
            pendingClaims[id] = continuation
            claimWaiters.removeValue(forKey: id)?.resume()
          }
        }
      }

      func reconcile(_ request: AnswerRequest) async -> AnswerDecision? {
        let id = request.call.id
        reconciliations.append(id)
        reconciliationWaiters.removeValue(forKey: id)?.resume()
        switch decisions[id]?.1 {
        case .allow: return .allow(permit(id))
        case .refuse(let reason): return .refuse(reason.native)
        case .unknown, nil:
          try? await clock.sleep(for: request.remaining)
          return nil
        }
      }

      func release(_ permit: AnswerPermit, for request: AnswerRequest) async {
        let id = request.call.id
        releases.append(id)
      }

      func waitForClaim(_ id: CallID) async {
        if !claims.contains(id) { await withCheckedContinuation { claimWaiters[id] = $0 } }
      }

      func waitForReconciliation(_ id: CallID) async {
        if !reconciliations.contains(id) {
          await withCheckedContinuation { reconciliationWaiters[id] = $0 }
        }
      }

      func deliverLatePermit(_ id: CallID) -> Bool {
        guard let completion = pendingClaims.removeValue(forKey: id) else { return false }
        completion.resume(returning: .allow(permit(id)))
        return true
      }

      func finishClaims() {
        for completion in pendingClaims.values {
          completion.resume(returning: .unavailable(.network))
        }
        pendingClaims.removeAll()
      }

      private func permit(_ id: CallID) -> AnswerPermit { AnswerPermit(id: id.rawValue) }
    }
  }

  extension SpecV0.Refusal {
    package init(_ reason: AnswerRefusal) {
      switch reason {
      case .answeredElsewhere: self = .answeredElsewhere
      case .declinedElsewhere: self = .declinedElsewhere
      case .notAllowed: self = .notAllowed
      }
    }

    fileprivate var native: AnswerRefusal {
      switch self {
      case .answeredElsewhere: .answeredElsewhere
      case .declinedElsewhere: .declinedElsewhere
      case .notAllowed: .notAllowed
      }
    }
  }

  extension SpecJourney.Configuration {
    package var sdkConfiguration: VoIPConfiguration {
      return VoIPConfiguration(
        presentationPolicy: PresentationPolicy(
          previewsCallsAnsweredElsewhere: previewAnsweredElsewhere),
        supportsVideo: true,
        deadlines: Deadlines(
          ring: budgets.incomingRing.duration, placement: budgets.placement.duration,
          mediaPreparation: budgets.mediaPreparation.duration,
          audioActivation: budgets.audioActivation.duration,
          audioRecovery: budgets.audioRecovery.duration,
          connect: budgets.connection.duration, reconnect: budgets.reconnection.duration,
          outgoingNoAnswer: budgets.outgoingNoAnswer.duration),
        retention: .seconds(120),
        outgoingMedia: outgoingMedia == .whenProvided ? .whenProvided : .duringPlacement,
        answerBudget: AnswerBudget(
          total: budgets.answer.total.duration, claim: budgets.answer.claim.duration,
          reconciliation: budgets.answer.reconciliation.duration,
          settlementReserve: budgets.answer.settlementReserve.duration),
        maximumParticipatingCalls: maximumParticipatingCalls)
    }

  }

  extension SpecV0.ID {
    package var callID: CallID { CallID(rawValue: rawValue) }
    package var eventID: EventID { EventID(rawValue: rawValue) }
  }

  extension SpecV0.Party {
    package func sdkParty() throws(HandleError) -> Party {
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
    fileprivate var specRefusal: SpecV0.Refusal? {
      if case .noParticipationSlot = self { .notAllowed } else { nil }
    }

    fileprivate var specKind: SpecV0.ErrorKind {
      switch self {
      case .unknownCall: .unknownCall
      case .unsupported: .unsupported
      case .notAllowed: .invalidTransition
      case .refused: .systemFailed
      case .noParticipationSlot: .refused
      }
    }
  }

  extension Call {
    package var specLifecycle: SpecJourney.Lifecycle {
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
    fileprivate func matches(_ expected: SpecV0.EndResult, actionIDs: [ActionID: String]) -> Bool {
      switch (self, expected) {
      case (.ended(let actual), .ended(let expected)):
        actual.callID.rawValue.utf8.elementsEqual(expected.callID.rawValue.utf8)
          && actionIDs[actual.actionID] == expected.actionID.rawValue
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
      case .answerAuthorization(.refused): .refused
      case .answerAuthorization(.claimTimedOut): .claimTimedOut
      case .answerAuthorization(.unavailable): .authorityUnavailable
      case .answerAuthorization(.invalidBudget): .invalidConfiguration
      case .media: .mediaFailed
      case .audioActivationTimedOut, .audioRecoveryTimedOut, .connectTimedOut,
        .reconnectTimedOut, .actionTimedOut:
        .deadlineExceeded
      case .refused, .systemFailed, .atCapacity, .audioSession, .frameworkReset, .server:
        .systemFailed
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
