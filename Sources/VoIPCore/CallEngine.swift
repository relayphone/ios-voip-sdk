#if SWIFT_PACKAGE
  package import Foundation
#else
  import Foundation
#endif

/// Runs every call's state machine on ``VoIPActor`` and carries out its effects.
///
/// The engine keeps each call's ``CallMachine/State`` by call ID, including ended calls for the
/// configuration's retention, and carries out a transition's effects in the order the machine
/// returns them: action settlements, deadline timers, work for the calling framework and media,
/// then events for the app. It then sends the client a snapshot of the calls.
///
/// Work that arrives while other work runs, such as a callback that the calling framework makes
/// synchronously, waits until that work finishes, so that one transition's effects never
/// interleave with another's.
@VoIPActor
final class CallEngine {
  private let framework: any CallingFramework
  private let media: any CallMedia
  private let audio: (any AudioSession)?
  private let pushSource: (any PushSource)?
  private let configuration: VoIPConfiguration
  private let clock: EngineClock
  private let wallNow: @Sendable () -> Date
  private let authority: (any AnswerAuthority)?
  private var answers: [CallID: AnswerExchange] = [:]
  private var answerReceipts: [ActionID: Duration] = [:]
  /// App Answer and Resume requests waiting for the framework to perform the action.
  private var pendingParticipation: [CallID: ParticipationRequest] = [:]
  private let subscribers: Subscribers
  private let publish: @Sendable (Snapshot) -> Void

  /// Every call this device knows, including ended calls until the retention passes.
  private(set) var states: [CallID: CallMachine.State] = [:]
  private var attemptGeneration: UInt64 = 0
  /// The known calls in the order they began.
  private var order: [CallID] = []
  /// How each incoming call appeared after its first report.
  private var outcomes: [CallID: PresentationOutcome] = [:]
  /// Callbacks waiting for an incoming call's first report to complete.
  private var reportWaiters: [CallID: [@VoIPActor (PresentationOutcome) -> Void]] = [:]
  private var startWaiters:
    [CallMachine.AttemptID: @VoIPActor (Result<Void, ActionError>) -> Void] =
      [:]
  /// When each ended call ended.
  private var endedAt: [CallID: Duration] = [:]
  private var serverEvents = ServerEventHistory()
  private var timers: [TimerKey: Timer] = [:]
  private var preparations: [CallID: Task<Void, Never>] = [:]
  private var videoTasks: [CallID: Task<Result<Void, ActionError>, Never>] = [:]
  private var transportTask: Task<Void, Never>?
  private var preparedCalls: Set<CallID> = []
  private var isAudioActive = false
  private var isMediaAudioActive = false
  private var audioVideoMode: Bool?
  private var audioOwner: CallID?
  /// Whether the system interrupted active audio, and hasn't activated it again or ended the
  /// interruption.
  private var isAudioInterrupted = false
  private var backlog: [@VoIPActor () -> Void] = []
  private var isBusy = false
  private var published = Snapshot(revision: 0, calls: [], isAudioActive: false)

  nonisolated init(
    framework: any CallingFramework,
    media: any CallMedia,
    audio: (any AudioSession)?,
    pushSource: (any PushSource)?,
    configuration: VoIPConfiguration,
    clock: any Clock<Duration>,
    subscribers: Subscribers,
    authority: (any AnswerAuthority)? = nil,
    wallNow: @escaping @Sendable () -> Date = { Date() },
    publish: @escaping @Sendable (Snapshot) -> Void
  ) {
    self.framework = framework
    self.media = media
    self.audio = audio
    self.pushSource = pushSource
    self.configuration = configuration
    self.clock = EngineClock(clock)
    self.wallNow = wallNow
    self.subscribers = subscribers
    self.authority = authority
    self.publish = publish
  }

  /// Attaches the calling framework, the audio session and the push source.
  func attach() {
    let transport = media.transportEvents()
    transportTask = Task {
      for await event in transport {
        guard !Task.isCancelled else { return }
        #if DEBUG && (os(macOS) || (os(iOS) && targetEnvironment(simulator)))
          SimulatorTransport.record(event)
        #endif
      }
    }
    framework.attach(configuration: configuration) { [weak self] event in
      guard let self else { return }
      let deliveredAt = clock.now()
      serially { self.frameworkEvent(event, deliveredAt: deliveredAt) }
    }
    audio?.attach { [weak self] event in
      guard let self else { return }
      serially { self.audioSessionEvent(event) }
    }
    pushSource?.attach { [weak self] push, completion in
      guard let self else { return completion.finish() }
      serially { self.intake(push, completion) }
    }
  }

  // MARK: Requests from the app

  isolated deinit {
    transportTask?.cancel()
    for answer in answers.values { answer.close() }
  }

  /// Reports an incoming call that the app learned about outside a VoIP push.
  func report(_ incoming: IncomingCall) async -> PresentationOutcome {
    await withCheckedContinuation { continuation in
      exclusively {
        let resume: @VoIPActor (PresentationOutcome) -> Void = {
          continuation.resume(returning: $0)
        }
        if let state = states[incoming.id] {
          if case .reporting = state.phase {
            reportWaiters[incoming.id, default: []].append(resume)
          } else {
            resume(outcomes[incoming.id] ?? .presented)
          }
          return
        }
        switch admit(incoming) {
        case .reporting: reportWaiters[incoming.id, default: []].append(resume)
        case .settled(let outcome): resume(outcome)
        }
      }
    }
  }

  /// Requests an action. Start awaits native admission after the app places the call.
  func request(_ action: Action) async throws(ActionError) {
    let id = action.callID
    if case .end = action {
      _ = try end(id)
      return
    }
    if case .start(let outgoing) = action {
      let result = await withCheckedContinuation { continuation in
        start(outgoing) { continuation.resume(returning: $0) }
      }
      try result.get()
      return
    }
    let (call, reservation) = try exclusively { () throws(ActionError) -> (Call?, ActionID?) in
      guard let state = states[id] else { throw .unknownCall }
      let needsSlot = needsParticipationSlot(action, state: state)
      if needsSlot {
        guard pendingParticipation[id] == nil else { throw .notAllowed(state.call.status) }
        guard participationSlotAvailable else { throw .noParticipationSlot }
      }
      let call = try requested(handle(id, .requested(action)), for: id)
      // Join owns its reservation through the machine's requesting phase.
      guard call != nil, needsSlot, !action.isJoin else { return (call, nil) }
      let reservation = ActionID(rawValue: UUID())
      pendingParticipation[id] = ParticipationRequest(action: action, reservation: reservation)
      return (call, reservation)
    }
    try await send(action, for: call, reservation: reservation)
  }

  func start(
    _ outgoing: OutgoingCall, completion: @escaping @VoIPActor (Result<Void, ActionError>) -> Void
  ) {
    exclusively {
      if let state = states[outgoing.id] {
        return completion(.failure(.notAllowed(state.call.status)))
      }
      guard participationSlotAvailable else { return completion(.failure(.noParticipationSlot)) }
      begin(.outgoing(outgoing), startCompletion: completion)
    }
  }

  func end(_ id: CallID, actionID: ActionID = ActionID(rawValue: UUID())) throws(ActionError)
    -> EndResult
  {
    try exclusively { () throws(ActionError) in
      guard var state = states[id] else { throw .unknownCall }
      state.expireRetainedEnd(at: clock.now(), after: configuration.retention)
      if let result = state.endResult { return result }
      let receipt = state.endReceipt(for: actionID)
      handle(id, .localEnd(receipt))
      return .ended(receipt)
    }
  }

  var videoSnapshot: Snapshot { published }

  /// Serializes app/server mutations through the system report boundary, per call.
  func setVideo(_ id: CallID, enabled: Bool, source: VideoChangeSource) async throws(ActionError) {
    let previous = videoTasks[id]
    let task = Task { () -> Result<Void, ActionError> in
      _ = await previous?.value
      do throws(ActionError) {
        let call = try exclusively { () throws(ActionError) -> Call in
          guard let state = states[id] else { throw .unknownCall }
          guard !state.phase.isEnded else { throw .notAllowed(state.call.status) }
          guard configuration.supportsVideo, framework.supportsVideoChanges,
            !state.phase.isPreviewing
          else { throw .unsupported }
          return state.call
        }
        guard call.hasVideo != enabled else { return .success(()) }
        let confirmed = try await framework.setVideo(enabled, for: call)
        try exclusively { () throws(ActionError) in
          guard let state = states[id] else { throw .unknownCall }
          guard !state.phase.isEnded else { throw .notAllowed(state.call.status) }
          guard state.call.hasVideo != confirmed else { return }
          var updated = state.call
          updated.hasVideo = confirmed
          states[id]?.call = updated
          var audioFailed = false
          if audioCall?.id == id {
            do {
              try audio?.updateVideo(for: updated)
              audioVideoMode = confirmed
              audioOwner = id
            } catch { audioFailed = true }
          }
          #if DEBUG && (os(macOS) || targetEnvironment(simulator))
            SimulatorLifecycle.record(updated)
          #endif
          subscribers.yield(.videoChanged(updated, source))
          if audioFailed {
            handle(id, .audioConfigurationFailed)
            throw .refused(nil)
          }
        }
        guard confirmed == enabled else { throw .refused(nil) }
        return .success(())
      } catch { return .failure(error) }
    }
    videoTasks[id] = task
    try await task.value.get()
  }

  /// Joins a call, first creating it as a call preview when this device doesn't know it.
  ///
  /// Server events that arrived for the call before apply first, so a call that already ended
  /// can't be joined.
  func join(_ incoming: IncomingCall) async throws(ActionError) {
    let id = incoming.id
    let action = Action.join(id)
    let call = try exclusively { () throws(ActionError) -> Call? in
      if states[id] == nil {
        // Replay a retained end even when there is no slot to place a Join.
        guard participationSlotAvailable || serverEvents.hasBufferedEnd(for: .canonical(id))
        else { throw .noParticipationSlot }
        begin(.joining(incoming))
      }
      if needsParticipationSlot(action, state: states[id]), !participationSlotAvailable {
        throw .noParticipationSlot
      }
      return try requested(handle(id, .requested(action)), for: id)
    }
    try await send(action, for: call)
  }

  /// The call whose request the calling framework must accept, or `nil` when the SDK handled the
  /// request itself.
  private func requested(_ reply: Reply, for id: CallID) throws(ActionError) -> Call? {
    if let rejection = reply.rejection { throw rejection }
    return reply.request == nil ? nil : states[id]?.call
  }

  /// Asks the calling framework to accept a request, and returns the call to where it was if it
  /// refuses.
  private func send(_ action: Action, for call: Call?, reservation: ActionID? = nil)
    async throws(ActionError)
  {
    guard let call else { return }
    do throws(ActionError) {
      try await framework.request(action, for: call)
    } catch {
      serially {
        if let reservation, self.pendingParticipation[call.id]?.reservation == reservation {
          self.pendingParticipation[call.id] = nil
        }
        self.handle(call.id, .requestFailed(action))
      }
      throw error
    }
  }

  /// Records that the app placed a call that it was asked to start or join.
  func confirmPlaced(_ id: CallID) {
    exclusively {
      if case .placingStart = states[id]?.phase, expireIfDue(.placement, for: id) { return }
      handle(id, .placed)
    }
  }

  func provideMedia(_ id: CallID) throws(ActionError) {
    try exclusively { () throws(ActionError) in
      guard let state = states[id] else { throw .unknownCall }
      guard configuration.outgoingMedia == .whenProvided, !state.call.isIncoming else {
        throw .unsupported
      }
      guard let deferredMedia = state.deferredMedia else { throw .notAllowed(state.call.status) }
      if deferredMedia == .unprovided { handle(id, .provideMedia) }
    }
  }

  /// Records that the app couldn't place a call that it was asked to start or join.
  func confirmNotPlaced(_ id: CallID) {
    exclusively { handle(id, .notPlaced) }
  }

  func bindRemote(_ remoteID: RemoteCallID, to id: CallID) throws(ActionError) -> Snapshot {
    try exclusively { () throws(ActionError) in
      guard let state = states[id] else { throw .unknownCall }
      if state.call.remoteIDs.contains(remoteID) { return }
      guard !state.phase.isEnded else { throw .notAllowed(state.call.status) }
      let target = ServerEventTarget.alias(remoteID)
      guard resolve(target) == nil else { throw .remoteIdentityConflict(remoteID) }
      states[id]?.call.remoteIDs.insert(remoteID)
      for buffered in serverEvents.takeBuffered(for: target) {
        handle(id, .server(buffered.event, receipt: buffered.receipt))
      }
    }
    return published
  }

  /// Applies a server event that the app learned about outside a VoIP push.
  func receive(_ event: ServerEvent, target: ServerEventTarget, eventID: EventID) {
    exclusively { serverEvent(event, target: target, eventID: eventID) }
  }

  /// A deadline's timer fired. A timer whose deadline was disarmed or armed again since is stale
  /// and does nothing.
  func timerFired(_ deadline: CallMachine.Deadline, for id: CallID, generation: UInt64) {
    serially {
      let key = TimerKey(id: id, deadline: deadline)
      guard self.timers[key]?.generation == generation else { return }
      self.timers[key] = nil
      #if DEBUG && (os(macOS) || targetEnvironment(simulator))
        if deadline == .mediaPreparation, let call = self.states[id]?.call, call.isIncoming {
          SimulatorLifecycle.record(call, .joinDeadlineExpired)
        }
      #endif
      self.handle(id, .deadlineExpired(deadline, generation: generation))
    }
  }

  // MARK: Push intake

  private func intake(_ push: VoIPPush, _ completion: PushCompletion) {
    switch push {
    case .incoming(let incoming, let eventID):
      guard remember(eventID) != nil, states[incoming.id] == nil else {
        return satisfy(completion, parties: incoming.parties)
      }
      switch admit(incoming) {
      case .reporting:
        reportWaiters[incoming.id, default: []].append { _ in completion.finish() }
      case .settled(let outcome) where completion.mustReport:
        // A VoIP push must be reported even when the call doesn't ring here.
        let reason: EndReason =
          if case .refused(let failure) = outcome { .failed(failure) } else { .failed(.server) }
        reportThrowaway(parties: incoming.parties, reason: reason, then: completion.finish)
      case .settled:
        completion.finish()
      }
    case .serverEvent(let event, let id, let eventID):
      // Report at once, as for every push, then apply the event.
      satisfy(completion, parties: states[id]?.call.parties ?? [])
      serverEvent(event, target: .canonical(id), eventID: eventID)
    case .unrecognized:
      satisfy(completion, parties: [])
    }
  }

  /// Completes a push that brings no new call to present.
  ///
  /// When the push must be reported, the SDK reports a throwaway call under a new UUID and ends it
  /// at once, even when the push concerns a call that the system presents. The system doesn't
  /// count a second report of a call it already has as reporting the push, and terminates the app
  /// for it.
  private func satisfy(_ completion: PushCompletion, parties: [Party]) {
    guard completion.mustReport else { return completion.finish() }
    reportThrowaway(parties: parties, reason: .failed(.server), then: completion.finish)
  }

  /// Reports a call under a new UUID and ends it at once, so that a VoIP push is reported without
  /// presenting anything.
  ///
  /// The SDK doesn't keep the throwaway call, so the app hears nothing of it, and the SDK fails
  /// any action the system asks it to perform on the call. Other calls are left as they are.
  private func reportThrowaway(
    parties: [Party], reason: EndReason, then finish: @escaping @VoIPActor () -> Void
  ) {
    let call = Call(
      id: CallID(rawValue: UUID().uuidString), isIncoming: true, parties: parties,
      status: .ringing)
    framework.reportIncoming(call) { [weak self] _ in
      guard let self else { return finish() }
      serially(finish)
    }
    framework.reportEnded(call.id, reason: reason)
  }

  private enum Admission {
    /// The call was reported to the calling framework, which hasn't answered yet.
    case reporting
    /// The call wasn't reported to the calling framework.
    case settled(PresentationOutcome)
  }

  /// Creates a new incoming call.
  private func admit(_ incoming: IncomingCall) -> Admission {
    let policy = incoming.presentationPolicy ?? configuration.presentationPolicy
    let presented = states.values.count { !$0.phase.isPreviewing && !$0.phase.isEnded }
    if policy.incoming == .ring, presented >= configuration.maximumCalls {
      refuseAtCapacity(incoming, policy: policy)
      return .settled(.refused(.atCapacity))
    }
    begin(.incoming(incoming))
    switch policy.incoming {
    case .ring:
      return .reporting
    case .preview:
      outcomes[incoming.id] = .previewed(.policy)
      return .settled(.previewed(.policy))
    case .none:
      return .settled(.notShown)
    }
  }

  /// Ends an incoming call that would ring beyond the configuration's maximum number of calls.
  private func refuseAtCapacity(_ incoming: IncomingCall, policy: PresentationPolicy) {
    let reason = EndReason.failed(.atCapacity)
    let call = Call(incoming, status: .ended(reason))
    states[call.id] = CallMachine.State(call: call, phase: .ended(reason), policy: policy)
    order.append(call.id)
    endedAt[call.id] = clock.now()
    outcomes[call.id] = .refused(.atCapacity)
    _ = serverEvents.takeBuffered(for: .canonical(call.id))
    subscribers.yield(.ended(call))
    #if DEBUG && (os(macOS) || targetEnvironment(simulator))
      SimulatorLifecycle.record(call, .ended)
    #endif
  }

  private func resolve(_ target: ServerEventTarget) -> CallID? {
    switch target {
    case .canonical(let id):
      return states[id] == nil ? nil : id
    case .alias(let remoteID):
      return states.values.first {
        !$0.phase.isEnded && $0.call.remoteIDs.contains(remoteID)
      }?.call.id
    }
  }

  private func remember(_ eventID: EventID) -> CallMachine.ServerReceipt? {
    serverEvents.remember(eventID, at: clock.now(), limit: configuration.eventHistoryLimit)
  }

  private func serverEvent(_ event: ServerEvent, target: ServerEventTarget, eventID: EventID) {
    guard let receipt = remember(eventID) else { return }
    if let id = resolve(target) {
      handle(id, .server(event, receipt: receipt))
    } else {
      serverEvents.buffer(
        event, target: target, id: eventID, receipt: receipt, limit: configuration.eventHistoryLimit
      )
    }
  }

  // MARK: The calling framework

  private func frameworkEvent(_ event: FrameworkEvent, deliveredAt: Duration) {
    switch event {
    case .perform(let actionID, let action):
      perform(actionID, action)
    case .performAnswer(let actionID, let id, let remaining, let elapsed):
      perform(
        actionID, .answer(id), received: deliveredAt - elapsed,
        nativeDeadline: deliveredAt + remaining)
    case .actionTimedOut(let actionID):
      for id in liveCalls { handle(id, .actionTimedOut(actionID)) }
    case .audioActivated:
      isAudioActive = true
      isAudioInterrupted = false
      activateMediaAudio()
      for id in liveCalls { handle(id, .audioActivated) }
      subscribers.yield(.audioActivated)
    case .audioDeactivated:
      // An interruption or a media services reset may have stopped the media already.
      stopAudio()
      subscribers.yield(.audioDeactivated)
    case .reset:
      for id in order {
        guard let state = states[id],
          !state.phase.isEnded || state.admissionAttempt != nil || state.startAttempt != nil
        else { continue }
        handle(id, .frameworkReset)
        if state.admissionAttempt != nil { finishReport(id, .refused(.frameworkReset)) }
      }
    }
  }

  private var participationSlotAvailable: Bool {
    participatingCallIDs.count < configuration.maximumParticipatingCalls
  }

  fileprivate var participatingCallIDs: Set<CallID> {
    Set(
      states.values.lazy.filter {
        $0.reservesParticipation || self.pendingParticipation[$0.call.id] != nil
      }.map { $0.call.id })
  }

  private func needsParticipationSlot(_ action: Action, state: CallMachine.State?) -> Bool {
    switch action {
    case .answer: state?.phase == .ringing && state?.answer == nil
    case .start: state == nil
    case .join: state == nil || state?.phase.isPreviewing == true
    case .hold(_, onHold: false):
      state?.phase.isActive == true && state?.awaitsNativeStart == false
        && state?.call.isOnHold == true && state?.reservesParticipation == false
        && configuration.capabilities.contains(.holding)
    default: false
    }
  }

  private func perform(
    _ actionID: ActionID, _ action: Action, received: Duration? = nil,
    nativeDeadline: Duration? = nil
  ) {
    #if DEBUG && (os(macOS) || targetEnvironment(simulator))
      switch action {
      case .answer, .join:
        if let call = states[action.callID]?.call { SimulatorLifecycle.record(call, .accept) }
      default: break
      }
    #endif
    let id = action.callID
    let state = states[id]
    if authority != nil, action.isAnswer {
      guard answers[id]?.attempt.action != actionID, answerReceipts[actionID] == nil else { return }
      answerReceipts[actionID] = clock.now()
      if answerReceipts.count > 256, let oldest = answerReceipts.min(by: { $0.value < $1.value }) {
        answerReceipts[oldest.key] = nil
      }
    }
    // The framework receipt takes over the request's reservation in this same engine turn.
    if pendingParticipation[id]?.action == action { pendingParticipation[id] = nil }
    if needsParticipationSlot(action, state: state), !participationSlotAvailable {
      framework.fail(actionID)
      if action.isAnswer, let state {
        subscribers.yield(.answerFailed(state.call, actionID, .refused(.notAllowed)))
      }
      return
    }
    guard state != nil else {
      if case .start(let outgoing) = action {
        begin(.systemStart(actionID, outgoing))
      } else {
        framework.fail(actionID)
      }
      return
    }
    guard authority != nil, action.isAnswer else {
      handle(id, .performed(actionID, action))
      return
    }
    if expireIfDue(.ring, for: id) { return framework.fail(actionID) }
    let anchor = received ?? clock.now()
    let total = min(
      configuration.answerBudget.total,
      nativeDeadline.map { $0 - anchor } ?? configuration.answerBudget.total)
    attemptGeneration += 1
    handle(
      id,
      .answerRequested(
        .init(
          generation: .init(generation: attemptGeneration), action: actionID,
          received: anchor, total: total)))
  }

  private var liveCalls: [CallID] {
    order.filter { states[$0]?.phase.isEnded == false }
  }

  private func activateMediaAudio() {
    guard isAudioActive, !isMediaAudioActive,
      !preparedCalls.isEmpty
        || (authority == nil && configuration.outgoingMedia == .duringPlacement)
    else { return }
    isMediaAudioActive = true
    media.activate()
  }

  /// Marks audio inactive, and stops the media when it was using audio.
  private func stopAudio() {
    guard isAudioActive else { return }
    isAudioActive = false
    if isMediaAudioActive {
      isMediaAudioActive = false
      media.deactivate()
    }
  }

  // MARK: The audio session

  private func audioSessionEvent(_ event: AudioSessionEvent) {
    switch event {
    case .interruptionBegan(let reason):
      // Only an interruption of active audio concerns calls.
      guard isAudioActive else { return }
      stopAudio()
      isAudioInterrupted = true
      subscribers.yield(.audioInterrupted(reason))
    case .interruptionEnded:
      guard isAudioInterrupted else { return }
      isAudioInterrupted = false
      for id in liveCalls { handle(id, .audioInterruptionEnded) }
    case .mediaServicesReset:
      stopAudio()
      isAudioInterrupted = false
      subscribers.yield(.mediaServicesReset)
      configureAfterReset()
    }
  }

  /// Configures the audio session again after the media services reset, for the newest call that
  /// takes part and isn't on hold, then waits for the system to activate audio again. When the
  /// session refuses, every call it was configured for ends.
  private func configureAfterReset() {
    let configured = liveCalls.compactMap { id in
      states[id].flatMap { $0.hasAudioConfiguration ? $0.call : nil }
    }
    if let audio, let call = configured.last(where: { !$0.isOnHold }) ?? configured.last {
      do throws(AudioSessionError) {
        try audio.configure(for: call)
        audioVideoMode = call.hasVideo
        audioOwner = call.id
      } catch {
        for call in configured { handle(call.id, .audioConfigurationFailed) }
        return
      }
    }
    for id in liveCalls { handle(id, .mediaServicesReset) }
  }

  // MARK: Transitions

  /// What a transition asks of the app's request.
  private struct Reply {
    var request: Action?
    var rejection: ActionError?
  }

  @discardableResult
  private func begin(
    _ origin: CallMachine.Origin,
    startCompletion: (@VoIPActor (Result<Void, ActionError>) -> Void)? = nil
  ) -> Reply {
    attemptGeneration += 1
    guard
      let (state, effects) = CallMachine.begin(
        origin, attempt: .init(generation: attemptGeneration),
        configuration: configuration, now: clock.date())
    else { return Reply() }
    let id = state.call.id
    if let attempt = state.startAttempt { startWaiters[attempt] = startCompletion }
    states[id] = state
    order.append(id)
    #if DEBUG && (os(macOS) || targetEnvironment(simulator))
      SimulatorLifecycle.record(state.call)
    #endif
    var pending = serverEvents.takeBuffered(for: .canonical(id))
    if case .reporting = state.phase {
      for buffered in pending where buffered.event.endReason != nil {
        handle(id, .server(buffered.event, receipt: buffered.receipt))
      }
      pending.removeAll { $0.event.endReason != nil }
    }
    let reply = run(effects, for: id)
    for buffered in pending { handle(id, .server(buffered.event, receipt: buffered.receipt)) }
    return reply
  }

  @discardableResult
  private func handle(_ id: CallID, _ event: CallMachine.Event) -> Reply {
    guard let state = states[id] else { return Reply() }
    let (next, effects) = CallMachine.transition(
      state, event, configuration: configuration, now: clock.date(), elapsed: clock.now())
    states[id] = next
    if next.phase.isEnded || next.phase.isPreviewing { pendingParticipation[id] = nil }
    #if DEBUG && (os(macOS) || targetEnvironment(simulator))
      let kind: SimulatorLifecycle.Event.Kind =
        next.phase.isEnded && !state.phase.isEnded
        ? .ended
        : next.call.connectedAt != nil && state.call.connectedAt == nil ? .connected : .state
      SimulatorLifecycle.record(next.call, kind)
    #endif
    return run(effects, for: id)
  }

  private func reportCompleted(
    _ id: CallID, attempt: CallMachine.AttemptID, outcome: PresentationOutcome
  ) {
    guard states[id]?.admissionAttempt == attempt else { return }
    let resolved: PresentationOutcome
    switch outcome {
    case .refused(.systemFailed(let failure)) where failure.operation == .admission:
      handle(id, .admissionFailed(attempt, failure))
      resolved = outcome
    case .refused(.refused):
      let failure = SystemFailure(platform: framework.platform, operation: .admission)
      handle(id, .admissionFailed(attempt, failure))
      resolved = .refused(.systemFailed(failure))
    default:
      handle(id, .reportCompleted(outcome))
      resolved = outcome
    }
    finishReport(id, resolved)
  }

  private func finishReport(_ id: CallID, _ outcome: PresentationOutcome) {
    // The policy may preview a call that the system filtered, or that was answered elsewhere
    // while it was being reported.
    let appearance: PresentationOutcome =
      if case .previewing(let reason) = states[id]?.phase { .previewed(reason) } else { outcome }
    if outcomes[id] == nil { outcomes[id] = appearance }
    for waiter in reportWaiters.removeValue(forKey: id) ?? [] { waiter(appearance) }
  }

  fileprivate func startCompleted(
    _ outgoing: OutgoingCall, attempt: CallMachine.AttemptID, result: Result<ActionID, ActionError>
  ) {
    let id = outgoing.id
    guard states[id]?.startAttempt == attempt else {
      if case .success(let action) = result { framework.fail(action) }
      return
    }
    // The platform callback and the timer may be queued together at the no-answer deadline.
    expireIfDue(.ring, for: id)
    switch result {
    case .success(let action):
      handle(id, .startAdmitted(attempt, action, outgoing))
      if isAudioActive, states[id]?.startedHere == true { handle(id, .audioActivated) }
    case .failure(let error):
      let diagnostic: SystemFailure.Diagnostic? =
        if case .refused(let detail?) = error { .framework(detail) } else { nil }
      handle(
        id,
        .startFailed(
          attempt,
          .init(
            platform: framework.platform, operation: .start, diagnostic: diagnostic)))
    }
  }

  @discardableResult
  private func expireIfDue(_ deadline: CallMachine.Deadline, for id: CallID) -> Bool {
    let key = TimerKey(id: id, deadline: deadline)
    guard let timer = timers[key], timer.due <= clock.now() else { return false }
    timers.removeValue(forKey: key)?.task.cancel()
    handle(id, .deadlineExpired(deadline, generation: timer.generation))
    return true
  }

  /// Carries out a transition's effects in order.
  private func run(_ effects: [CallMachine.Effect], for id: CallID) -> Reply {
    settle(id)

    var reply = Reply()
    for effect in effects {
      switch effect {
      case .reportIncoming(let call):
        guard let attempt = states[id]?.admissionAttempt else { preconditionFailure() }
        framework.reportIncoming(call) { [weak self] outcome in
          guard let self else { return }
          serially { self.reportCompleted(call.id, attempt: attempt, outcome: outcome) }
        }
      case .request(let action): reply.request = action
      case .requestStart(let attempt, let outgoing, let call):
        framework.requestStart(outgoing, for: call) { [weak self] result in
          guard let self else { return }
          serially { self.startCompleted(outgoing, attempt: attempt, result: result) }
        }
      case .removeLateStart(let action, let reason):
        framework.removeLateStart(action, for: id, reason: reason)
      case .settleStart(let attempt, let error):
        startWaiters.removeValue(forKey: attempt)?(error.map { .failure($0) } ?? .success(()))
      case .reject(_, let error): reply.rejection = error
      case .fulfill(let action): framework.fulfill(action)
      case .fail(let action): framework.fail(action)
      case .update(let call): framework.update(call)
      case .reportOutgoing(let call, let connected):
        framework.reportOutgoing(call, connected: connected)
      case .reportEnded(let call, let reason):
        let systemReason =
          reason == .unanswered && states[call]?.call.isIncoming == false
          ? EndReason.endedRemotely : reason
        framework.reportEnded(call, reason: systemReason)
      case .prepareMedia(let call): prepare(call)
      case .requestAnswer(let attempt, let stage, let deadline):
        requestAnswer(id, attempt: attempt, stage: stage, deadline: deadline)
      case .armAt(let deadline, let due, let generation):
        arm(TimerKey(id: id, deadline: deadline), due: due, generation: generation)
      case .arm(let deadline, let duration, let generation):
        arm(TimerKey(id: id, deadline: deadline), after: duration, generation: generation)
      case .disarm(let deadline, let generation):
        let key = TimerKey(id: id, deadline: deadline)
        if timers[key]?.generation == generation { timers.removeValue(forKey: key)?.task.cancel() }
      case .emit(let event): subscribers.yield(event)
      }
    }
    return reply
  }

  /// Keeps the engine's records in step with a call's new phase.
  private func settle(_ id: CallID) {
    guard let state = states[id] else { return }
    if state.phase.isEnded || state.phase.isPreviewing,
      preparedCalls.remove(id) != nil
    {
      media.release(state.call)
    }
    if state.phase.isEnded || state.phase.isPreviewing {
      answers.removeValue(forKey: id)?.close()
    }
    if !state.phase.isPreparing, state.deferredMedia != .preparing, state.answer?.permit == nil {
      preparations.removeValue(forKey: id)?.cancel()
    }
    if state.phase.isEnded, endedAt[id] == nil { endedAt[id] = clock.now() }
  }

  private func arm(_ key: TimerKey, after duration: Duration, generation: UInt64) {
    arm(key, due: clock.now() + duration, generation: generation)
  }

  private func arm(_ key: TimerKey, due: Duration, generation: UInt64) {
    timers[key]?.task.cancel()
    let task = Task { [weak self, clock] in
      do { try await clock.sleep(due) } catch { return }
      self?.timerFired(key.deadline, for: key.id, generation: generation)
    }
    timers[key] = Timer(generation: generation, due: due, task: task)
  }

  /// Configures the audio session for the call, then prepares its media.
  private func prepare(_ call: Call) {
    preparations.removeValue(forKey: call.id)?.cancel()
    if let audio {
      do throws(AudioSessionError) {
        try audio.configure(for: call)
        audioVideoMode = call.hasVideo
        audioOwner = call.id
      } catch {
        // The transition that asked for the preparation finishes first.
        serially { self.handle(call.id, .audioConfigurationFailed) }
        return
      }
    }
    let permit = states[call.id]?.answer?.permit
    preparations[call.id] = Task { [weak self, media, wallNow] in
      let event: CallMachine.Event
      do {
        let now = wallNow()
        if let expiry = permit?.expiresAt, expiry <= now {
          throw AnswerMediaPreparationError.expired
        }
        if let credentials = permit?.mediaCredentials {
          guard credentials.expiresAt > now else { throw AnswerMediaPreparationError.expired }
          try await media.prepare(call, answerCredentials: credentials)
        } else {
          try await media.prepare(call)
        }
        event = .mediaPrepared
      } catch {
        event = .mediaPreparationFailed
      }
      guard let self, !Task.isCancelled else { return }
      serially {
        if case .mediaPrepared = event { self.preparedCalls.insert(call.id) }
        let state = self.states[call.id]
        let isBounded = state?.answer?.permit != nil || state?.phase.isPreparingStart == true
        if isBounded, self.expireIfDue(.mediaPreparation, for: call.id) {
          return
        }
        self.handle(call.id, event)
        if case .mediaPrepared = event, self.isAudioActive {
          if self.states[call.id]?.deferredMedia == .prepared {
            self.handle(call.id, .audioActivated)
          }
          self.activateMediaAudio()
        }
      }
    }
  }

  private func requestAnswer(
    _ id: CallID, attempt: CallMachine.AnswerAttempt, stage: CallMachine.Deadline,
    deadline: Duration
  ) {
    guard let authority, let call = states[id]?.call else { return }
    let exchange =
      answers[id]
      ?? AnswerExchange(attempt: attempt, call: call, authority: authority, clock: clock)
    answers[id] = exchange
    let request = exchange.request(deadline: deadline)
    guard request.remaining > .zero else { return }
    exchange.tasks[stage] = Task { [weak self] in
      defer { exchange.tasks[stage] = nil }
      guard !Task.isCancelled, request.remaining > .zero else { return }
      let result =
        if stage == .claim { await authority.claim(request) } else {
          await authority.reconcile(request)
        }
      exchange.tasks[stage] = nil
      let cleanup: Task<Void, Never>?
      if let self {
        cleanup = exclusively { answerCompleted(exchange, stage: stage, result: result) }
      } else if case .allow(let permit) = result {
        cleanup = exchange.release(permit)
      } else {
        cleanup = nil
      }
      await cleanup?.value
    }
  }

  private func answerCompleted(
    _ exchange: AnswerExchange, stage: CallMachine.Deadline, result: AnswerDecision?
  ) -> Task<Void, Never>? {
    let id = exchange.call.id
    if answers[id] === exchange {
      expireIfDue(.claim, for: id)
      expireIfDue(.reconciliation, for: id)
    }
    let isCurrent = answers[id] === exchange
    if isCurrent, states[id]?.armed[stage] != nil {
      if case .allow(let permit) = result {
        let now = wallNow()
        if permit.expiresAt.map({ $0 <= now }) == true
          || permit.mediaCredentials.map({ $0.expiresAt <= now }) == true
        {
          let cleanup = exchange.release(permit)
          handle(
            id,
            .answerResolved(
              exchange.attempt.generation, stage: stage, .unavailable(.invalidResponse))
          )
          return cleanup
        }
        exchange.adopt(permit)
      }
      handle(id, .answerResolved(exchange.attempt.generation, stage: stage, result))
    } else if case .allow(let permit) = result {
      if isCurrent, states[id]?.armed[.reconciliation] != nil {
        // The two replies can identify the same grant. Let reconciliation decide which to keep.
        exchange.lateClaimPermit = AnswerPermit(id: permit.id)
      } else {
        return exchange.releaseUnlessAdopted(permit)
      }
    }
    return nil
  }

  // MARK: Running work

  /// Runs work from outside the engine, or queues it behind the work that is running.
  private func serially(_ work: @escaping @VoIPActor () -> Void) {
    guard !isBusy else { return backlog.append(work) }
    isBusy = true
    prune()
    work()
    finishWork()
  }

  /// Runs an app request, which always starts in its own job, and returns its result.
  @discardableResult
  private func exclusively<Result, Failure: Error>(
    _ body: () throws(Failure) -> Result
  ) throws(Failure) -> Result {
    assert(!isBusy, "An app request runs in its own job")
    isBusy = true
    defer { finishWork() }
    prune()
    return try body()
  }

  private var audioCall: Call? {
    order.reversed().compactMap { id in
      states[id].flatMap { $0.hasAudioConfiguration && !$0.call.isOnHold ? $0.call : nil }
    }.first
  }

  private func finishWork() {
    while true {
      while !backlog.isEmpty { backlog.removeFirst()() }
      guard let audio, let call = audioCall,
        audioOwner != call.id || audioVideoMode != call.hasVideo
      else { break }
      audioVideoMode = call.hasVideo
      audioOwner = call.id
      do { try audio.updateVideo(for: call) } catch { handle(call.id, .audioConfigurationFailed) }
    }
    isBusy = false
    let calls = order.compactMap { id -> Call? in
      guard let state = states[id] else { return nil }
      switch state.phase {
      case .reporting, .ended: return nil
      default: return state.call
      }
    }
    guard calls != published.calls || isAudioActive != published.isAudioActive else { return }
    published = Snapshot(
      revision: published.revision + 1, calls: calls, isAudioActive: isAudioActive)
    publish(published)
  }

  /// Forgets ended calls, event IDs and early server events once the retention passed.
  private func prune() {
    let now = clock.now()
    let retention = configuration.retention
    answerReceipts = answerReceipts.filter { now - $0.value < retention }
    serverEvents.prune(at: now, after: retention)
    for (id, ended) in endedAt
    where now - ended >= retention && reportWaiters[id] == nil && states[id]?.startAttempt == nil {
      endedAt[id] = nil
      states[id] = nil
      videoTasks[id] = nil
      outcomes[id] = nil
    }
    order.removeAll { states[$0] == nil }
  }

  #if SWIFT_PACKAGE
    fileprivate var timeUntilNextDeadline: Duration? {
      timers.values.map(\.due).min().map { max(.zero, $0 - clock.now()) }
    }

    /// Joins due timers and preparation tasks when the test media port completes immediately.
    fileprivate func synchronize() async {
      while true {
        let now = clock.now()
        // A due timer can cancel media preparation.
        let tasks = timers.values.filter { $0.due <= now }.map(\.task) + preparations.values
        guard !tasks.isEmpty else { return }
        for task in tasks { await task.value }
      }
    }

    fileprivate func answerTask(for id: CallID, stage: CallMachine.Deadline) -> Task<Void, Never>? {
      answers[id]?.tasks[stage]
    }

    fileprivate func cancelWork() {
      for timer in timers.values { timer.task.cancel() }
      for preparation in preparations.values { preparation.cancel() }
      for answer in answers.values { answer.close() }
      answers.removeAll()
    }
  #endif
}

#if SWIFT_PACKAGE
  /// Package access to the same engine and event stream used by VoIPClient, with retained calls
  /// and a synchronization point for deterministic port tests.
  @VoIPActor
  package final class SpecEngine {
    package enum Phase: Sendable {
      case reporting, placing, visible
    }

    private let engine: CallEngine

    package init(
      framework: any CallingFramework, media: any CallMedia, push: any PushSource,
      configuration: VoIPConfiguration, clock: any Clock<Duration>,
      authority: (any AnswerAuthority)? = nil,
      wallNow: @escaping @Sendable () -> Date = { Date() },
      observe: @escaping @VoIPActor @Sendable (CallEvent) -> Void
    ) {
      engine = CallEngine(
        framework: framework, media: media, audio: nil, pushSource: push,
        configuration: configuration, clock: clock, subscribers: Subscribers(observe: observe),
        authority: authority, wallNow: wallNow, publish: { _ in })
      engine.attach()
    }

    package var calls: [Call] { engine.states.values.map(\.call) }

    package var participating: Set<CallID> {
      engine.participatingCallIDs
    }

    package func phase(for id: CallID) -> Phase {
      switch engine.states[id]?.phase {
      case .reporting: .reporting
      case .requesting, .placing, .placingStart: .placing
      default: .visible
      }
    }

    package func request(_ action: Action) async throws(ActionError) {
      try await engine.request(action)
    }

    package func start(
      _ outgoing: OutgoingCall, completion: @escaping @VoIPActor (Result<Void, ActionError>) -> Void
    ) {
      engine.start(outgoing, completion: completion)
    }

    /// Replays admission with a generation that was never assigned to this call.
    package func replayStaleStartAdmission(_ outgoing: OutgoingCall, action: ActionID) {
      engine.startCompleted(outgoing, attempt: .init(generation: 0), result: .success(action))
    }

    package func end(_ id: CallID, actionID: ActionID = ActionID(rawValue: UUID()))
      throws(ActionError)
      -> EndResult
    {
      try engine.end(id, actionID: actionID)
    }

    package func setVideo(_ id: CallID, enabled: Bool) async throws(ActionError) {
      try await engine.setVideo(id, enabled: enabled, source: .app)
    }

    package func confirmPlaced(_ id: CallID) { engine.confirmPlaced(id) }

    package func provideMedia(_ id: CallID) throws(ActionError) { try engine.provideMedia(id) }

    package func receive(_ event: ServerEvent, for id: CallID, eventID: EventID) {
      engine.receive(event, target: .canonical(id), eventID: eventID)
    }

    package func receive(_ event: ServerEvent, forRemote id: RemoteCallID, eventID: EventID) {
      engine.receive(event, target: .alias(id), eventID: eventID)
    }

    package func bindRemote(_ remoteID: RemoteCallID, to id: CallID) throws(ActionError) {
      _ = try engine.bindRemote(remoteID, to: id)
    }

    package var timeUntilNextDeadline: Duration? { engine.timeUntilNextDeadline }
    package func synchronize() async { await engine.synchronize() }
    package func answerTask(_ id: CallID, reconciling: Bool = false) -> Task<Void, Never>? {
      engine.answerTask(for: id, stage: reconciling ? .reconciliation : .claim)
    }
    package func close() { engine.cancelWork() }
  }
#endif

/// The client's view of the engine: its calls that haven't ended, and whether audio is active.
struct Snapshot: Sendable {
  /// Increases with each snapshot, so that the client never applies an older one.
  let revision: UInt64
  let calls: [Call]
  let isAudioActive: Bool
}

private struct ParticipationRequest {
  let action: Action
  let reservation: ActionID
}

private struct TimerKey: Hashable {
  let id: CallID
  let deadline: CallMachine.Deadline
}

private struct Timer {
  let generation: UInt64
  let due: Duration
  let task: Task<Void, Never>
}

/// The injected clock, measured from when the engine started.
private struct EngineClock: Sendable {
  /// The time elapsed since the engine started.
  let now: @Sendable () -> Duration
  /// Sleeps until the given time since the engine started.
  let sleep: @Sendable (Duration) async throws -> Void
  private let origin: Date

  init<C: Clock<Duration>>(_ clock: C) {
    let start = clock.now
    now = { start.duration(to: clock.now) }
    sleep = { try await clock.sleep(until: start.advanced(by: $0), tolerance: nil) }
    origin = Date()
  }

  /// The current date on the injected clock, for the times the SDK records on calls.
  func date() -> Date {
    let (seconds, attoseconds) = now().components
    return origin.addingTimeInterval(Double(seconds) + Double(attoseconds) / 1e18)
  }
}

/// Owns the original receipt and compensates late results even after the call is pruned.
@VoIPActor
private final class AnswerExchange {
  let attempt: CallMachine.AnswerAttempt
  let call: Call
  let authority: any AnswerAuthority
  let clock: EngineClock
  var tasks: [CallMachine.Deadline: Task<Void, Never>] = [:]
  var lateClaimPermit: AnswerPermit?
  private var adopted: AnswerPermit?
  private var releases: Set<Data> = []

  init(
    attempt: CallMachine.AnswerAttempt, call: Call, authority: any AnswerAuthority,
    clock: EngineClock
  ) {
    self.attempt = attempt
    self.call = call
    self.authority = authority
    self.clock = clock
  }

  func request(deadline: Duration) -> AnswerRequest {
    AnswerRequest(
      call: call, actionID: attempt.action, deadline: deadline, now: clock.now, sleep: clock.sleep)
  }

  func adopt(_ permit: AnswerPermit) {
    adopted = AnswerPermit(id: permit.id)
    if let lateClaimPermit { releaseUnlessAdopted(lateClaimPermit) }
    lateClaimPermit = nil
  }

  func close() {
    for task in tasks.values { task.cancel() }
    tasks.removeAll()
    if let adopted { release(adopted) }
    if let lateClaimPermit { release(lateClaimPermit) }
    adopted = nil
    lateClaimPermit = nil
  }

  @discardableResult
  func releaseUnlessAdopted(_ permit: AnswerPermit) -> Task<Void, Never>? {
    adopted?.id.utf8.elementsEqual(permit.id.utf8) == true ? nil : release(permit)
  }

  @discardableResult
  func release(_ permit: AnswerPermit) -> Task<Void, Never>? {
    guard releases.insert(Data(permit.id.utf8)).inserted else { return nil }
    let now = clock.now()
    let answerDeadline = attempt.received + attempt.total
    let cleanup = now + .seconds(1)
    let request = request(deadline: now < answerDeadline ? min(cleanup, answerDeadline) : cleanup)
    return Task { [authority] in await authority.release(permit, for: request) }
  }
}

extension CallMachine.Phase {
  fileprivate var isPreparingStart: Bool {
    if case .preparingStart = self { true } else { false }
  }
  var isEnded: Bool {
    if case .ended = self { true } else { false }
  }

  fileprivate var isPreparing: Bool {
    switch self {
    case .preparing, .preparingStart: true
    default: false
    }
  }
}
