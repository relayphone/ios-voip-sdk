import Foundation

/// The state machine for one call.
///
/// ``begin(_:configuration:now:)`` creates a call and ``transition(_:_:configuration:now:)``
/// moves it on by one event. Both are pure: they return the next state and the effects the engine
/// carries out, in order, and read no clock.
///
/// The machine keeps these invariants:
/// - Every action the calling framework asks it to perform is fulfilled or failed exactly once.
/// - Every deadline is armed and disarmed by effects that carry a generation, so the engine can
///   ignore a timer that fires after its deadline was disarmed.
/// - Every path to ``Phase/ended(_:)`` settles the held action, disarms every deadline and emits
///   ``CallEvent/ended(_:)`` once. An ended call ignores every later event.
/// - A call preview never involves the calling framework.
enum CallMachine {
  /// How a call begins on this device.
  enum Origin: Hashable, Sendable {
    /// An incoming call, presented according to its presentation policy.
    case incoming(IncomingCall)
    /// The app asked to start an outgoing call.
    case outgoing(OutgoingCall)
    /// The calling framework started an outgoing call from a system surface, such as Recents,
    /// without a request from the app.
    case systemStart(ActionID, OutgoingCall)
    /// The user is joining a call that this device didn't know, such as one whose call preview
    /// the app's servers started. It begins as a call preview without telling the app, because
    /// the join follows at once.
    case joining(IncomingCall)
  }

  /// A framework action that the machine holds until the call can take part.
  struct HeldAction: Hashable, Sendable {
    let id: ActionID
    let action: Action
  }

  /// Where a call is in the machine. ``CallStatus`` is the public projection of the phase.
  enum Phase: Hashable, Sendable {
    /// The incoming call is reported to the calling framework, which hasn't said whether it
    /// presented the call. A server event that ends the call is remembered until then.
    case reporting(endOnPresent: EndReason?)
    /// The incoming call rings.
    case ringing
    /// The call is live elsewhere and followed in a call preview.
    case previewing(PreviewReason)
    /// The app's start or join request is with the calling framework.
    case requesting(Action)
    /// The calling framework performed the start or join; the app is placing the call.
    case placing(HeldAction)
    /// The call's media is being prepared before the held answer, start or join is fulfilled.
    case preparing(HeldAction)
    /// The outgoing call is placed and the other side's device rings.
    case dialing
    /// The call was answered or joined and its media is connecting.
    case connecting
    /// The call is connected.
    case connected
    /// The call's media is reconnecting.
    case reconnecting
    /// The call ended.
    case ended(EndReason)
  }

  /// A timer the machine arms while it waits for something to happen.
  enum Deadline: Hashable, Sendable, CaseIterable {
    case ring
    case placement
    case mediaPreparation
    case audioActivation
    case audioRecovery
    case connect
    case reconnect
  }

  /// A server's progress report that arrived before the call could take part.
  enum EarlyProgress: Hashable, Sendable {
    case connecting
    case connected
  }

  /// One call's state.
  struct State: Hashable, Sendable {
    /// The call as the app sees it. Its status always matches ``phase``.
    var call: Call
    var phase: Phase
    /// The call's presentation policy, resolved when the call began.
    var policy: PresentationPolicy
    /// Why the call was last a call preview. It is kept while the call joins, so that a join that
    /// fails before the call takes part returns to the same preview.
    var previewReason: PreviewReason?
    /// Whether the calling framework sees the call as started on this device: an outgoing call,
    /// or a call joined from its preview, once it takes part.
    var startedHere = false
    var earlyProgress: EarlyProgress?
    /// The generation of every armed deadline.
    var armed: [Deadline: UInt64] = [:]
    var lastGeneration: UInt64 = 0
  }

  /// Something that happened to the call.
  enum Event: Hashable, Sendable {
    /// The calling framework finished reporting the incoming call.
    case reportCompleted(PresentationOutcome)
    /// The calling framework asks the SDK to perform an action.
    case performed(ActionID, Action)
    /// The calling framework stopped waiting for an action.
    case actionTimedOut(ActionID)
    /// The system activated the audio session.
    case audioActivated
    /// The audio session couldn't be configured for the call.
    case audioConfigurationFailed
    /// An interruption of active audio ended, and audio is still inactive.
    case audioInterruptionEnded
    /// The media services reset, and the audio session was configured again.
    case mediaServicesReset
    /// The calling framework reset, ending every call it presents.
    case frameworkReset
    /// The app requested an action.
    case requested(Action)
    /// The calling framework refused a request.
    case requestFailed(Action)
    /// The app placed the call it was asked to start or join.
    case placed
    /// The app couldn't place the call it was asked to start or join.
    case notPlaced
    /// The call's media is prepared.
    case mediaPrepared
    /// The call's media couldn't be prepared.
    case mediaPreparationFailed
    /// The app's servers reported a fact about the call.
    case server(ServerEvent)
    /// A deadline's timer fired.
    case deadlineExpired(Deadline, generation: UInt64)
  }

  /// Work for the engine.
  enum Effect: Hashable, Sendable {
    /// Report the incoming call to the calling framework.
    case reportIncoming(Call)
    /// Send the app's request to the calling framework.
    case request(Action)
    /// Refuse the app's request.
    case reject(Action, ActionError)
    /// Complete a framework action successfully.
    case fulfill(ActionID)
    /// Complete a framework action as failed.
    case fail(ActionID)
    /// Update the call's details in the calling framework.
    case update(Call)
    /// Tell the calling framework that a call started here began connecting, or connected.
    case reportOutgoing(CallID, connected: Bool)
    /// Tell the calling framework that the call ended.
    case reportEnded(CallID, EndReason)
    /// Prepare the call's media.
    case prepareMedia(Call)
    /// Start a deadline's timer.
    case arm(Deadline, after: Duration, generation: UInt64)
    /// Cancel a deadline's timer.
    case disarm(Deadline, generation: UInt64)
    /// Tell the app.
    case emit(CallEvent)
  }
}

extension CallMachine.Phase {
  /// The call status that this phase shows the app.
  var status: CallStatus {
    switch self {
    case .reporting, .ringing: .ringing
    case .previewing(let reason): .previewing(reason)
    case .requesting(let action): action.isStart ? .dialing : .connecting
    case .placing(let held), .preparing(let held): held.action.isStart ? .dialing : .connecting
    case .dialing: .dialing
    case .connecting: .connecting
    case .connected: .connected
    case .reconnecting: .reconnecting
    case .ended(let reason): .ended(reason)
    }
  }

  /// The framework action this phase holds.
  var held: CallMachine.HeldAction? {
    switch self {
    case .placing(let held), .preparing(let held): held
    default: nil
    }
  }

  /// Whether the call is a call preview.
  var isPreviewing: Bool {
    if case .previewing = self { true } else { false }
  }

  /// Whether this device is joining a call from its preview and doesn't take part yet.
  var isJoining: Bool {
    switch self {
    case .requesting(let action): action.isJoin
    case .placing(let held), .preparing(let held): held.action.isJoin
    default: false
    }
  }

  /// Whether the calling framework presents the call and it can be held, muted or play tones.
  var isActive: Bool {
    switch self {
    case .placing, .preparing, .dialing, .connecting, .connected, .reconnecting: true
    default: false
    }
  }

  /// Whether the call takes part on this device: its answer, start or join completed, so the
  /// system activates audio for it.
  var isTakingPart: Bool {
    switch self {
    case .dialing, .connecting, .connected, .reconnecting: true
    default: false
    }
  }

  /// Whether the audio session is configured for the call: it is preparing its media, or it
  /// takes part.
  var hasAudioConfiguration: Bool {
    if case .preparing = self { true } else { isTakingPart }
  }
}

extension Action {
  var isStart: Bool {
    if case .start = self { true } else { false }
  }

  var isJoin: Bool {
    if case .join = self { true } else { false }
  }

  var isAnswer: Bool {
    if case .answer = self { true } else { false }
  }
}

extension Deadlines {
  subscript(deadline: CallMachine.Deadline) -> Duration {
    switch deadline {
    case .ring: ring
    case .placement: placement
    case .mediaPreparation: mediaPreparation
    case .audioActivation: audioActivation
    case .audioRecovery: audioRecovery
    case .connect: connect
    case .reconnect: reconnect
    }
  }
}
