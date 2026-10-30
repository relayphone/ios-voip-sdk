import Foundation

extension CallMachine {
  /// Creates a call on this device.
  ///
  /// - Returns: The call's state and the effects to carry out, or `nil` for an incoming call whose
  ///   presentation policy is ``PresentationPolicy/Presentation/none``, which doesn't exist on
  ///   this device.
  static func begin(
    _ origin: Origin, configuration: VoIPConfiguration, now: Date
  ) -> (State, [Effect])? {
    switch origin {
    case .incoming(let incoming):
      let policy = incoming.presentationPolicy ?? configuration.presentationPolicy
      let call = Call(
        id: incoming.id, isIncoming: true, parties: incoming.parties, status: .ringing,
        hasVideo: incoming.hasVideo, metadata: incoming.metadata)
      switch policy.incoming {
      case .ring:
        var step = Step(
          call: call, phase: .reporting(endOnPresent: nil), policy: policy,
          configuration: configuration, now: now)
        step.output(.reportIncoming(step.state.call))
        return step.result
      case .preview:
        var step = Step(
          call: call, phase: .previewing(.policy), policy: policy,
          configuration: configuration, now: now)
        step.emit(.previewStarted(step.state.call))
        return step.result
      case .none:
        return nil
      }
    case .outgoing(let outgoing):
      let action = Action.start(outgoing)
      var step = Step(
        call: Call(outgoing), phase: .requesting(action),
        policy: configuration.presentationPolicy, configuration: configuration,
        now: now)
      step.arm(.placement)
      step.output(.request(action))
      return step.result
    case .systemStart(let id, let outgoing):
      let held = HeldAction(id: id, action: .start(outgoing))
      var step = Step(
        call: Call(outgoing), phase: .placing(held),
        policy: configuration.presentationPolicy, configuration: configuration,
        now: now)
      step.arm(.placement)
      step.emit(.startRequested(step.state.call))
      return step.result
    }
  }

  /// Moves a call on by one event.
  ///
  /// Events are for this call. An event that doesn't apply to the call's phase leaves it
  /// unchanged, except that a framework action is failed and an app request is rejected.
  static func transition(
    _ state: State, _ event: Event, configuration: VoIPConfiguration, now: Date
  ) -> (State, [Effect]) {
    var step = Step(state: state, configuration: configuration, now: now)
    step.apply(event)
    return step.result
  }
}

/// One transition in progress. Effects are returned grouped in a fixed order: action
/// settlements, then deadline timers, then work for the calling framework and media, then events
/// for the app.
private struct Step {
  typealias Deadline = CallMachine.Deadline
  typealias Effect = CallMachine.Effect
  typealias Phase = CallMachine.Phase

  var state: CallMachine.State
  let configuration: VoIPConfiguration
  let now: Date
  private var settlements: [Effect] = []
  private var timers: [Effect] = []
  private var outputs: [Effect] = []
  private var events: [Effect] = []

  init(state: CallMachine.State, configuration: VoIPConfiguration, now: Date) {
    self.state = state
    self.configuration = configuration
    self.now = now
  }

  init(
    call: Call, phase: Phase, policy: PresentationPolicy, configuration: VoIPConfiguration,
    now: Date
  ) {
    self.init(
      state: CallMachine.State(call: call, phase: phase, policy: policy),
      configuration: configuration, now: now)
    enter(phase)
  }

  var result: (CallMachine.State, [Effect]) {
    (state, settlements + timers + outputs + events)
  }

  // MARK: Events

  mutating func apply(_ event: CallMachine.Event) {
    switch event {
    case .reportCompleted(let outcome): reportCompleted(outcome)
    case .performed(let id, let action): perform(id, action)
    case .actionTimedOut(let id):
      if state.phase.held?.id == id { abandon(.actionTimedOut) }
    case .audioActivated: disarm(.audioActivation)
    case .frameworkReset: frameworkReset()
    case .requested(let action): request(action)
    case .requestFailed(let action): requestFailed(action)
    case .placed: placed()
    case .mediaPrepared: mediaPrepared()
    case .mediaPreparationFailed:
      if case .preparing = state.phase { abandon(.media) }
    case .server(let event): server(event)
    case .deadlineExpired(let deadline, let generation):
      guard state.armed[deadline] == generation else { return }
      state.armed[deadline] = nil
      expire(deadline)
    }
  }

  private mutating func reportCompleted(_ outcome: PresentationOutcome) {
    guard case .reporting(let remembered) = state.phase else { return }
    let presented = outcome == .presented
    switch (outcome, remembered) {
    case (_, .answeredElsewhere?):
      answeredElsewhere(frameworkPresentsCall: presented)
    case (_, let reason?):
      end(reason, reportingEnd: presented)
    case (.presented, nil):
      enter(.ringing)
      arm(.ring)
      emit(.presented(state.call))
    case (.filtered(let cause), nil):
      if state.policy.previewsFilteredCalls {
        preview(.filtered(cause), reportingEnd: nil)
      } else {
        end(.filtered(cause), reportingEnd: false)
      }
    case (.refused(let failure), nil):
      end(.failed(failure), reportingEnd: false)
    }
  }

  private mutating func perform(_ id: ActionID, _ action: Action) {
    let capabilities = configuration.capabilities
    switch (state.phase, action) {
    case (.ringing, .answer):
      state.call.answeredAt = now
      disarm(.ring)
      enter(.preparing(CallMachine.HeldAction(id: id, action: action)))
      arm(.mediaPreparation)
      output(.prepareMedia(state.call))
    case (.requesting(let requested), .start), (.requesting(let requested), .join):
      guard requested.isStart == action.isStart, requested.callID == action.callID else {
        return fail(id)
      }
      enter(.placing(CallMachine.HeldAction(id: id, action: action)))
      emit(action.isStart ? .startRequested(state.call) : .joinRequested(state.call))
    case (_, .end) where state.phase == .ringing || state.phase.isActive:
      if state.phase.isJoining {
        returnToPreview(fulfilling: id)
      } else {
        end(.endedHere, reportingEnd: false, fulfilling: id, performed: action)
      }
    case (_, .hold(_, let onHold))
    where state.phase.isActive && capabilities.contains(.holding):
      fulfill(id)
      state.call.isOnHold = onHold
      emit(.performed(action, state.call))
    case (_, .mute(_, let muted)) where state.phase.isActive:
      fulfill(id)
      state.call.isMuted = muted
      emit(.performed(action, state.call))
    case (_, .playTones) where state.phase.isActive && capabilities.contains(.playingTones),
      (_, .merge) where state.phase.isActive && capabilities.contains(.merging),
      (_, .unmerge) where state.phase.isActive && capabilities.contains(.merging):
      fulfill(id)
      emit(.performed(action, state.call))
    default:
      fail(id)
    }
  }

  private mutating func request(_ action: Action) {
    let capabilities = configuration.capabilities
    let phase = state.phase
    switch action {
    case .start:
      reject(action, .notAllowed(state.call.status))
    case .answer:
      guard phase == .ringing else { return reject(action, .notAllowed(state.call.status)) }
      output(.request(action))
    case .join:
      guard phase.isPreviewing else { return reject(action, .notAllowed(state.call.status)) }
      enter(.requesting(action))
      arm(.placement)
      output(.request(action))
    case .end:
      switch phase {
      case .previewing: end(.endedHere, reportingEnd: false, performed: action)
      case .reporting, .ended: reject(action, .notAllowed(state.call.status))
      default: output(.request(action))
      }
    case .hold, .playTones, .merge, .unmerge:
      let needed: VoIPConfiguration.Capabilities =
        switch action {
        case .hold: .holding
        case .playTones: .playingTones
        default: .merging
        }
      guard capabilities.contains(needed) else { return reject(action, .unsupported) }
      guard phase.isActive else { return reject(action, .notAllowed(state.call.status)) }
      output(.request(action))
    case .mute:
      guard phase.isActive else { return reject(action, .notAllowed(state.call.status)) }
      output(.request(action))
    }
  }

  private mutating func requestFailed(_ action: Action) {
    guard case .requesting(let requested) = state.phase, requested == action else { return }
    if action.isJoin {
      returnToPreview()
    } else {
      end(.failed(.refused), reportingEnd: false)
    }
  }

  private mutating func placed() {
    guard case .placing(let held) = state.phase else { return }
    disarm(.placement)
    enter(.preparing(held))
    arm(.mediaPreparation)
    output(.prepareMedia(state.call))
  }

  private mutating func mediaPrepared() {
    guard case .preparing(let held) = state.phase else { return }
    fulfill(held.id)
    disarm(.mediaPreparation)
    arm(.audioActivation)
    state.startedHere = !held.action.isAnswer
    if state.startedHere {
      output(.reportOutgoing(state.call.id, connected: false))
    }
    switch (held.action, state.earlyProgress) {
    case (_, .connected?):
      becomeConnected()
    case (.start, nil):
      enter(.dialing)
      arm(.ring)
    default:
      enter(.connecting)
      arm(.connect)
    }
    state.earlyProgress = nil
    emit(.performed(held.action, state.call))
  }

  private mutating func server(_ event: ServerEvent) {
    let phase = state.phase
    switch event {
    case .partiesChanged(let parties):
      if case .ended = phase { return }
      state.call.parties = parties
      if !phase.isPreviewing { output(.update(state.call)) }
    case .connecting:
      switch phase {
      case .dialing:
        disarm(.ring)
        enter(.connecting)
        arm(.connect)
      case .placing, .preparing:
        state.earlyProgress = state.earlyProgress ?? .connecting
      default:
        break
      }
    case .connected:
      switch phase {
      case .dialing:
        disarm(.ring)
        becomeConnected()
      case .connecting:
        disarm(.connect)
        becomeConnected()
      case .reconnecting:
        disarm(.reconnect)
        enter(.connected)
      case .placing, .preparing:
        state.earlyProgress = .connected
      default:
        break
      }
    case .reconnecting:
      guard phase == .connected else { return }
      enter(.reconnecting)
      arm(.reconnect)
    case .answeredElsewhere:
      switch phase {
      case .reporting:
        enter(.reporting(endOnPresent: .answeredElsewhere))
      case .ringing:
        answeredElsewhere(frameworkPresentsCall: true)
      case .preparing(let held) where held.action.isAnswer:
        answeredElsewhere(frameworkPresentsCall: true)
      case .connecting where !state.startedHere:
        answeredElsewhere(frameworkPresentsCall: true)
      default:
        break
      }
    case .endedRemotely: serverEnded(.endedRemotely)
    case .declinedElsewhere: serverEnded(.declinedElsewhere)
    case .unanswered: serverEnded(.unanswered)
    case .failed: serverEnded(.failed(.server))
    }
  }

  /// The app's servers reported that the call is over. While it is being reported, the reason
  /// waits for the calling framework's answer.
  private mutating func serverEnded(_ reason: EndReason) {
    switch state.phase {
    case .reporting: enter(.reporting(endOnPresent: reason))
    case .previewing: end(reason, reportingEnd: false)
    case .ended: break
    default: end(reason, reportingEnd: true)
    }
  }

  private mutating func expire(_ deadline: Deadline) {
    switch deadline {
    case .ring: end(.unanswered, reportingEnd: true)
    case .placement: abandon(.notPlaced)
    case .mediaPreparation: abandon(.media)
    case .audioActivation: end(.failed(.audioActivationTimedOut), reportingEnd: true)
    case .connect: end(.failed(.connectTimedOut), reportingEnd: true)
    case .reconnect: end(.failed(.reconnectTimedOut), reportingEnd: true)
    }
  }

  private mutating func frameworkReset() {
    switch state.phase {
    case .previewing, .ended:
      break
    case let phase where phase.isJoining:
      returnToPreview()
    default:
      end(.failed(.frameworkReset), reportingEnd: false)
    }
  }

  // MARK: Outcomes

  /// The call was answered on another device, or by a service acting for the user, before it
  /// took part here.
  private mutating func answeredElsewhere(frameworkPresentsCall: Bool) {
    if state.policy.previewsCallsAnsweredElsewhere {
      preview(.answeredElsewhere, reportingEnd: frameworkPresentsCall ? .answeredElsewhere : nil)
    } else {
      end(.answeredElsewhere, reportingEnd: frameworkPresentsCall)
    }
  }

  /// Something failed before the call took part: a join returns to its preview, and any other
  /// call ends.
  private mutating func abandon(_ failure: CallFailure) {
    if state.phase.isJoining {
      returnToPreview(reportingEnd: .failed(failure))
    } else {
      end(.failed(failure), reportingEnd: true)
    }
  }

  /// Moves the call to a call preview, removing it from the calling framework.
  private mutating func preview(
    _ reason: PreviewReason, reportingEnd endReason: EndReason?,
    fulfilling endAction: ActionID? = nil
  ) {
    if let held = state.phase.held { fail(held.id) }
    if let endAction { fulfill(endAction) }
    disarmAll()
    if let endReason { output(.reportEnded(state.call.id, endReason)) }
    state.startedHere = false
    state.earlyProgress = nil
    state.call.isMuted = false
    state.call.isOnHold = false
    enter(.previewing(reason))
    emit(.previewStarted(state.call))
  }

  /// Returns a call that was joining to the preview it was joined from.
  private mutating func returnToPreview(
    reportingEnd endReason: EndReason? = nil, fulfilling endAction: ActionID? = nil
  ) {
    // A call can only join from a preview, so the reason is always known here.
    preview(state.previewReason ?? .policy, reportingEnd: endReason, fulfilling: endAction)
  }

  /// Ends the call. This is the only way into ``CallMachine/Phase/ended(_:)``.
  private mutating func end(
    _ reason: EndReason, reportingEnd: Bool, fulfilling endAction: ActionID? = nil,
    performed action: Action? = nil
  ) {
    if let held = state.phase.held { fail(held.id) }
    if let endAction { fulfill(endAction) }
    disarmAll()
    if reportingEnd { output(.reportEnded(state.call.id, reason)) }
    state.earlyProgress = nil
    enter(.ended(reason))
    if let action { emit(.performed(action, state.call)) }
    emit(.ended(state.call))
  }

  private mutating func becomeConnected() {
    enter(.connected)
    if state.call.connectedAt == nil { state.call.connectedAt = now }
    if state.startedHere { output(.reportOutgoing(state.call.id, connected: true)) }
  }

  // MARK: Effects

  private mutating func enter(_ phase: Phase) {
    state.phase = phase
    state.call.status = phase.status
    if case .previewing(let reason) = phase { state.previewReason = reason }
  }

  mutating func arm(_ deadline: Deadline) {
    disarm(deadline)
    state.lastGeneration += 1
    state.armed[deadline] = state.lastGeneration
    timers.append(
      .arm(deadline, after: configuration.deadlines[deadline], generation: state.lastGeneration))
  }

  private mutating func disarm(_ deadline: Deadline) {
    guard let generation = state.armed.removeValue(forKey: deadline) else { return }
    timers.append(.disarm(deadline, generation: generation))
  }

  private mutating func disarmAll() {
    for deadline in Deadline.allCases { disarm(deadline) }
  }

  private mutating func fulfill(_ id: ActionID) {
    settlements.append(.fulfill(id))
  }

  private mutating func fail(_ id: ActionID) {
    settlements.append(.fail(id))
  }

  private mutating func reject(_ action: Action, _ error: ActionError) {
    outputs.append(.reject(action, error))
  }

  mutating func output(_ effect: Effect) {
    outputs.append(effect)
  }

  mutating func emit(_ event: CallEvent) {
    events.append(.emit(event))
  }
}

extension Call {
  /// A new outgoing call, before its status is set.
  fileprivate init(_ outgoing: OutgoingCall) {
    self.init(
      id: outgoing.id, isIncoming: false, parties: outgoing.parties, status: .dialing,
      hasVideo: outgoing.hasVideo, metadata: outgoing.metadata)
  }
}
