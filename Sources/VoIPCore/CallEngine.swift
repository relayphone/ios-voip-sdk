import Foundation

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
  private let pushSource: (any PushSource)?
  private let configuration: VoIPConfiguration
  private let clock: EngineClock
  private let subscribers: Subscribers
  private let publish: @Sendable (Snapshot) -> Void

  /// Every call this device knows, including ended calls until the retention passes.
  private(set) var states: [CallID: CallMachine.State] = [:]
  /// The known calls in the order they began.
  private var order: [CallID] = []
  /// What the calling framework did with each incoming call's first report.
  private var outcomes: [CallID: PresentationOutcome] = [:]
  /// Callbacks waiting for an incoming call's first report to complete.
  private var reportWaiters: [CallID: [@VoIPActor (PresentationOutcome) -> Void]] = [:]
  /// When each ended call ended.
  private var endedAt: [CallID: Duration] = [:]
  /// When each event ID was first seen.
  private var seenEvents: [EventID: Duration] = [:]
  /// Server events for calls this device doesn't know yet, in arrival order.
  private var earlyEvents: [CallID: [EarlyEvent]] = [:]
  private var timers: [TimerKey: Timer] = [:]
  private var preparations: [CallID: Task<Void, Never>] = [:]
  private var isAudioActive = false
  private var backlog: [@VoIPActor () -> Void] = []
  private var isBusy = false
  private var published = Snapshot(revision: 0, calls: [], isAudioActive: false)

  nonisolated init(
    framework: any CallingFramework,
    media: any CallMedia,
    pushSource: (any PushSource)?,
    configuration: VoIPConfiguration,
    clock: any Clock<Duration>,
    subscribers: Subscribers,
    publish: @escaping @Sendable (Snapshot) -> Void
  ) {
    self.framework = framework
    self.media = media
    self.pushSource = pushSource
    self.configuration = configuration
    self.clock = EngineClock(clock)
    self.subscribers = subscribers
    self.publish = publish
  }

  /// Attaches the calling framework and the push source.
  func attach() {
    framework.attach(configuration: configuration) { [weak self] event in
      guard let self else { return }
      serially { self.frameworkEvent(event) }
    }
    pushSource?.attach { [weak self] push, completion in
      guard let self else { return completion.finish() }
      serially { self.intake(push, completion) }
    }
  }

  // MARK: Requests from the app

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

  /// Requests an action, returning once the calling framework accepted it or the SDK performed it.
  func request(_ action: Action) async throws(ActionError) {
    let id = action.callID
    let call = try exclusively { () throws(ActionError) -> Call? in
      let reply: Reply
      if states[id] != nil {
        reply = handle(id, .requested(action))
      } else if case .start(let outgoing) = action {
        reply = begin(.outgoing(outgoing))
      } else {
        throw .unknownCall
      }
      if let rejection = reply.rejection { throw rejection }
      return reply.request == nil ? nil : states[id]?.call
    }
    guard let call else { return }
    do throws(ActionError) {
      try await framework.request(action, for: call)
    } catch {
      serially { self.handle(id, .requestFailed(action)) }
      throw error
    }
  }

  /// Records that the app placed a call that it was asked to start or join.
  func confirmPlaced(_ id: CallID) {
    exclusively { handle(id, .placed) }
  }

  /// Applies a server event that the app learned about outside a VoIP push.
  func receive(_ event: ServerEvent, for id: CallID, eventID: EventID) {
    exclusively { serverEvent(event, for: id, eventID: eventID) }
  }

  /// A deadline's timer fired. A timer whose deadline was disarmed or armed again since is stale
  /// and does nothing.
  func timerFired(_ deadline: CallMachine.Deadline, for id: CallID, generation: UInt64) {
    serially {
      let key = TimerKey(id: id, deadline: deadline)
      guard self.timers[key]?.generation == generation else { return }
      self.timers[key] = nil
      self.handle(id, .deadlineExpired(deadline, generation: generation))
    }
  }

  // MARK: Push intake

  private func intake(_ push: VoIPPush, _ completion: PushCompletion) {
    switch push {
    case .incoming(let incoming, let eventID):
      let isRepeated = seenEvents[eventID] != nil || states[incoming.id] != nil
      if seenEvents[eventID] == nil { seenEvents[eventID] = clock.now() }
      if isRepeated {
        return satisfy(completion, for: incoming.id, parties: incoming.parties)
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
      // Report first, so that a call the system still presents is reported under its own UUID.
      satisfy(completion, for: id, parties: states[id]?.call.parties ?? [])
      serverEvent(event, for: id, eventID: eventID)
    case .unrecognized:
      satisfy(completion, for: nil, parties: [])
    }
  }

  /// Completes a push that brings no new call to present.
  ///
  /// When the system presents the call, reporting it again under its own UUID presents nothing
  /// new. Otherwise the SDK reports a throwaway call and ends it at once.
  private func satisfy(_ completion: PushCompletion, for id: CallID?, parties: [Party]) {
    guard completion.mustReport else { return completion.finish() }
    if let id, let state = states[id], state.phase.isWithFramework {
      framework.reportIncoming(state.call) { [weak self] _ in
        guard let self else { return completion.finish() }
        serially { completion.finish() }
      }
    } else {
      reportThrowaway(parties: parties, reason: .failed(.server), then: completion.finish)
    }
  }

  /// Reports a call under a new UUID and ends it at once, so that a VoIP push is reported without
  /// presenting anything.
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
      outcomes[incoming.id] = .presented
      return .settled(.presented)
    case .none:
      return .settled(.presented)
    }
  }

  /// Ends an incoming call that would ring beyond the configuration's maximum number of calls.
  private func refuseAtCapacity(_ incoming: IncomingCall, policy: PresentationPolicy) {
    let reason = EndReason.failed(.atCapacity)
    let call = Call(
      id: incoming.id, isIncoming: true, parties: incoming.parties, status: .ended(reason),
      hasVideo: incoming.hasVideo, metadata: incoming.metadata)
    states[call.id] = CallMachine.State(call: call, phase: .ended(reason), policy: policy)
    order.append(call.id)
    endedAt[call.id] = clock.now()
    outcomes[call.id] = .refused(.atCapacity)
    earlyEvents[call.id] = nil
    subscribers.yield(.ended(call))
  }

  private func serverEvent(_ event: ServerEvent, for id: CallID, eventID: EventID) {
    guard seenEvents[eventID] == nil else { return }
    seenEvents[eventID] = clock.now()
    if states[id] != nil {
      handle(id, .server(event))
    } else {
      earlyEvents[id, default: []].append(EarlyEvent(event: event, receivedAt: clock.now()))
    }
  }

  // MARK: The calling framework

  private func frameworkEvent(_ event: FrameworkEvent) {
    switch event {
    case .perform(let actionID, let action):
      if states[action.callID] != nil {
        handle(action.callID, .performed(actionID, action))
      } else if case .start(let outgoing) = action {
        begin(.systemStart(actionID, outgoing))
      } else {
        framework.fail(actionID)
      }
    case .actionTimedOut(let actionID):
      for id in liveCalls { handle(id, .actionTimedOut(actionID)) }
    case .audioActivated:
      isAudioActive = true
      media.activate()
      for id in liveCalls { handle(id, .audioActivated) }
      subscribers.yield(.audioActivated)
    case .audioDeactivated:
      isAudioActive = false
      media.deactivate()
      subscribers.yield(.audioDeactivated)
    case .reset:
      for id in liveCalls { handle(id, .frameworkReset) }
    }
  }

  private var liveCalls: [CallID] {
    order.filter { states[$0]?.phase.isEnded == false }
  }

  // MARK: Transitions

  /// What a transition asks of the app's request.
  private struct Reply {
    var request: Action?
    var rejection: ActionError?
  }

  @discardableResult
  private func begin(_ origin: CallMachine.Origin) -> Reply {
    guard
      let (state, effects) = CallMachine.begin(
        origin, configuration: configuration, now: clock.date())
    else { return Reply() }
    let id = state.call.id
    states[id] = state
    order.append(id)
    let reply = run(effects, for: id)
    settle(id)
    for early in earlyEvents.removeValue(forKey: id) ?? [] { handle(id, .server(early.event)) }
    return reply
  }

  @discardableResult
  private func handle(_ id: CallID, _ event: CallMachine.Event) -> Reply {
    guard let state = states[id] else { return Reply() }
    let (next, effects) = CallMachine.transition(
      state, event, configuration: configuration, now: clock.date())
    states[id] = next
    let reply = run(effects, for: id)
    settle(id)
    return reply
  }

  private func reportCompleted(_ id: CallID, _ outcome: PresentationOutcome) {
    if outcomes[id] == nil { outcomes[id] = outcome }
    handle(id, .reportCompleted(outcome))
    for waiter in reportWaiters.removeValue(forKey: id) ?? [] { waiter(outcome) }
  }

  /// Carries out a transition's effects in order.
  private func run(_ effects: [CallMachine.Effect], for id: CallID) -> Reply {
    var reply = Reply()
    for effect in effects {
      switch effect {
      case .reportIncoming(let call):
        framework.reportIncoming(call) { [weak self] outcome in
          guard let self else { return }
          serially { self.reportCompleted(call.id, outcome) }
        }
      case .request(let action): reply.request = action
      case .reject(_, let error): reply.rejection = error
      case .fulfill(let action): framework.fulfill(action)
      case .fail(let action): framework.fail(action)
      case .update(let call): framework.update(call)
      case .reportOutgoing(let call, let connected):
        framework.reportOutgoing(call, connected: connected)
      case .reportEnded(let call, let reason): framework.reportEnded(call, reason: reason)
      case .prepareMedia(let call): prepare(call)
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
    guard let phase = states[id]?.phase else { return }
    if !phase.isPreparing { preparations.removeValue(forKey: id)?.cancel() }
    if phase.isEnded, endedAt[id] == nil { endedAt[id] = clock.now() }
  }

  private func arm(_ key: TimerKey, after duration: Duration, generation: UInt64) {
    timers[key]?.task.cancel()
    let due = clock.now() + duration
    let task = Task { [weak self, clock] in
      do { try await clock.sleep(due) } catch { return }
      self?.timerFired(key.deadline, for: key.id, generation: generation)
    }
    timers[key] = Timer(generation: generation, task: task)
  }

  private func prepare(_ call: Call) {
    preparations[call.id]?.cancel()
    preparations[call.id] = Task { [weak self, media] in
      let event: CallMachine.Event
      do {
        try await media.prepare(call)
        event = .mediaPrepared
      } catch {
        event = .mediaPreparationFailed
      }
      guard let self, !Task.isCancelled else { return }
      serially { self.handle(call.id, event) }
    }
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

  private func finishWork() {
    while !backlog.isEmpty { backlog.removeFirst()() }
    isBusy = false
    let calls = order.compactMap { states[$0] }.filter { !$0.phase.isEnded }.map(\.call)
    guard calls != published.calls || isAudioActive != published.isAudioActive else { return }
    published = Snapshot(
      revision: published.revision + 1, calls: calls, isAudioActive: isAudioActive)
    publish(published)
  }

  /// Forgets ended calls, event IDs and early server events once the retention passed.
  private func prune() {
    let now = clock.now()
    let retention = configuration.retention
    seenEvents = seenEvents.filter { now - $0.value < retention }
    earlyEvents = earlyEvents.compactMapValues { events in
      let kept = events.filter { now - $0.receivedAt < retention }
      return kept.isEmpty ? nil : kept
    }
    for (id, ended) in endedAt where now - ended >= retention {
      endedAt[id] = nil
      states[id] = nil
      outcomes[id] = nil
    }
    order.removeAll { states[$0] == nil }
  }
}

/// The client's view of the engine: its calls that haven't ended, and whether audio is active.
struct Snapshot: Sendable {
  /// Increases with each snapshot, so that the client never applies an older one.
  let revision: UInt64
  let calls: [Call]
  let isAudioActive: Bool
}

private struct TimerKey: Hashable {
  let id: CallID
  let deadline: CallMachine.Deadline
}

private struct Timer {
  let generation: UInt64
  let task: Task<Void, Never>
}

private struct EarlyEvent {
  let event: ServerEvent
  let receivedAt: Duration
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

extension CallMachine.Phase {
  fileprivate var isEnded: Bool {
    if case .ended = self { true } else { false }
  }

  fileprivate var isPreparing: Bool {
    if case .preparing = self { true } else { false }
  }

  /// Whether the calling framework has the call under its UUID.
  fileprivate var isWithFramework: Bool {
    switch self {
    case .reporting, .ringing: true
    default: isActive
    }
  }
}
