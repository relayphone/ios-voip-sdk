import Foundation
import Testing

@testable import VoIPCore

typealias Phase = CallMachine.Phase
typealias Deadline = CallMachine.Deadline
typealias Event = CallMachine.Event
typealias Effect = CallMachine.Effect
typealias State = CallMachine.State

let callID = CallID(rawValue: "call-1")
let otherCallID = CallID(rawValue: "call-2")
let epoch = Date(timeIntervalSince1970: 1_800_000_000)
let later = epoch.addingTimeInterval(5)

let alice: Party = {
  do {
    return try Party(
      handle: Handle(kind: .phoneNumber, value: "+14155550123"), displayName: "Alice")
  } catch {
    preconditionFailure("The fixture handle is valid: \(error)")
  }
}()

let outgoing = OutgoingCall(id: callID, parties: [alice])
let startAction = Action.start(outgoing)
let answer = Action.answer(callID)
let join = Action.join(callID)
let end = Action.end(callID)
let muteOn = Action.mute(callID, muted: true)
let holdOn = Action.hold(callID, onHold: true)
let tones = Action.playTones(callID, digits: "1")
let merge = Action.merge(callID, with: otherCallID)
let unmerge = Action.unmerge(callID)
let allActions = [
  startAction, answer, join, end, muteOn, .mute(callID, muted: false), holdOn,
  .hold(callID, onHold: false), tones, merge, unmerge,
]

func actionID(_ number: UInt16) -> ActionID {
  let high = UInt8(number >> 8)
  let low = UInt8(number & 0xFF)
  return ActionID(rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, high, low)))
}

let a1 = actionID(1)
let a2 = actionID(2)

func held(_ id: ActionID, _ action: Action) -> CallMachine.HeldAction {
  CallMachine.HeldAction(id: id, action: action)
}

let noPreviews = PresentationPolicy(
  previewsFilteredCalls: false, previewsCallsAnsweredElsewhere: false)
let withMerging = VoIPConfiguration(capabilities: [.holding, .playingTones, .merging])
let withoutCapabilities = VoIPConfiguration(capabilities: [])

func incoming(_ presentation: PresentationPolicy.Presentation, policy: PresentationPolicy)
  -> IncomingCall
{
  var policy = policy
  policy.incoming = presentation
  return IncomingCall(id: callID, parties: [alice], presentationPolicy: policy)
}

/// A named state, reached by running the machine from a call's origin.
enum Start: String, CaseIterable, Sendable, CustomTestStringConvertible {
  case reporting
  case reportingAnsweredElsewhere
  case reportingEndedRemotely
  case ringing
  case previewing
  case requestingStart
  case requestingJoin
  case placingStart
  case placingJoin
  case preparingAnswer
  case preparingStart
  case preparingStartConnected
  case preparingJoin
  case dialing
  case connectingAnswer
  case connectingStart
  case connectingJoin
  case connected
  case recoveringAudio
  case reconnecting
  case ended

  var testDescription: String { rawValue }

  /// The origin and events that reach this state.
  func path(policy: PresentationPolicy) -> (CallMachine.Origin, [Event]) {
    let ringingCall = CallMachine.Origin.incoming(incoming(.ring, policy: policy))
    let previewCall = CallMachine.Origin.incoming(incoming(.preview, policy: policy))
    switch self {
    case .reporting: return (ringingCall, [])
    case .reportingAnsweredElsewhere: return (ringingCall, [.server(.answeredElsewhere)])
    case .reportingEndedRemotely: return (ringingCall, [.server(.endedRemotely)])
    case .ringing: return (ringingCall, [.reportCompleted(.presented)])
    case .previewing: return (previewCall, [])
    case .requestingStart: return (.outgoing(outgoing), [])
    case .requestingJoin: return (previewCall, [.requested(join)])
    case .placingStart: return (.outgoing(outgoing), [.performed(a1, startAction)])
    case .placingJoin: return (previewCall, [.requested(join), .performed(a1, join)])
    default: break
    }
    let (base, events): (Start, [Event]) =
      switch self {
      case .preparingAnswer: (.ringing, [.performed(a1, answer)])
      case .preparingStart: (.placingStart, [.placed])
      case .preparingStartConnected: (.placingStart, [.server(.connected), .placed])
      case .preparingJoin: (.placingJoin, [.placed])
      case .dialing: (.preparingStart, [.mediaPrepared])
      case .connectingAnswer: (.preparingAnswer, [.mediaPrepared])
      case .connectingStart: (.dialing, [.server(.connecting)])
      case .connectingJoin: (.preparingJoin, [.mediaPrepared])
      case .connected: (.connectingAnswer, [.audioActivated, .server(.connected)])
      case .recoveringAudio: (.connected, [.audioInterruptionEnded])
      case .reconnecting: (.connected, [.server(.reconnecting)])
      default: (.ringing, [.server(.endedRemotely)])
      }
    let (origin, prefix) = base.path(policy: policy)
    return (origin, prefix + events)
  }

  func state(
    policy: PresentationPolicy = PresentationPolicy(),
    configuration: VoIPConfiguration = VoIPConfiguration()
  ) throws -> State {
    let (origin, events) = path(policy: policy)
    var (state, _) = try #require(
      CallMachine.begin(origin, configuration: configuration, now: epoch))
    for event in events {
      (state, _) = CallMachine.transition(state, event, configuration: configuration, now: epoch)
    }
    return state
  }
}

/// An effect with its call snapshots and generations left out, for comparing transitions.
enum Shape: Hashable, Sendable {
  case reportIncoming
  case request(Action)
  case reject(Action, ActionError)
  case fulfill(ActionID)
  case fail(ActionID)
  case update
  case reportOutgoing(connected: Bool)
  case reportEnded(EndReason)
  case prepareMedia
  case arm(Deadline)
  case disarm(Deadline)
  case presented
  case previewStarted
  case startRequested
  case joinRequested
  case performed(Action)
  case audioActivated
  case audioDeactivated
  case audioInterrupted(AudioInterruptionReason)
  case mediaServicesReset
  case ended(EndReason?)

  init(_ effect: Effect) {
    switch effect {
    case .reportIncoming: self = .reportIncoming
    case .request(let action): self = .request(action)
    case .reject(let action, let error): self = .reject(action, error)
    case .fulfill(let id): self = .fulfill(id)
    case .fail(let id): self = .fail(id)
    case .update: self = .update
    case .reportOutgoing(_, let connected): self = .reportOutgoing(connected: connected)
    case .reportEnded(_, let reason): self = .reportEnded(reason)
    case .prepareMedia: self = .prepareMedia
    case .arm(let deadline, _, _): self = .arm(deadline)
    case .disarm(let deadline, _): self = .disarm(deadline)
    case .emit(let event):
      switch event {
      case .presented: self = .presented
      case .previewStarted: self = .previewStarted
      case .startRequested: self = .startRequested
      case .joinRequested: self = .joinRequested
      case .performed(let action, _): self = .performed(action)
      case .audioActivated: self = .audioActivated
      case .audioDeactivated: self = .audioDeactivated
      case .audioInterrupted(let reason): self = .audioInterrupted(reason)
      case .mediaServicesReset: self = .mediaServicesReset
      case .ended(let call):
        if case .ended(let reason) = call.status {
          self = .ended(reason)
        } else {
          self = .ended(nil)
        }
      }
    }
  }
}

extension Effect {
  /// Every call snapshot the effect carries.
  var calls: [Call] {
    switch self {
    case .reportIncoming(let call), .update(let call), .prepareMedia(let call): [call]
    case .emit(let event):
      switch event {
      case .presented(let call), .previewStarted(let call), .startRequested(let call),
        .joinRequested(let call), .performed(_, let call), .ended(let call):
        [call]
      case .audioActivated, .audioDeactivated, .audioInterrupted, .mediaServicesReset: []
      }
    default: []
    }
  }

  var isEnded: Bool {
    if case .emit(.ended) = self { true } else { false }
  }
}

/// A small deterministic generator for random walks through the machine.
struct SplitMix64: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
