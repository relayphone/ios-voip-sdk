import Foundation
import Testing

@testable import VoIPCore

/// Follows one call through the machine and checks the invariants after every transition.
private struct InvariantChecker {
  let configuration: VoIPConfiguration
  private var performed: Set<ActionID> = []
  private var settled: Set<ActionID> = []
  private var armed: [Deadline: UInt64]
  private var lastGeneration: UInt64
  private var endedEvents: Int

  init(following state: State, configuration: VoIPConfiguration) {
    self.configuration = configuration
    performed = Set([state.phase.held?.id].compactMap(\.self))
    armed = state.armed
    lastGeneration = state.lastGeneration
    if case .ended = state.phase { endedEvents = 1 } else { endedEvents = 0 }
  }

  mutating func check(
    _ before: State, _ event: Event, _ after: State, _ effects: [Effect],
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(after.call.status == after.phase.status, sourceLocation: sourceLocation)
    for call in effects.flatMap(\.calls) {
      #expect(call == after.call, "effects carry the call as it is after the transition")
    }
    #expect(isGrouped(effects), "effects are grouped in order: \(effects)")

    // Every framework action is settled exactly once, and only the held one waits.
    if case .performed(let id, _) = event { performed.insert(id) }
    for effect in effects {
      switch effect {
      case .fulfill(let id), .fail(let id): settle(id, sourceLocation)
      default: break
      }
    }
    #expect(
      performed.subtracting(settled) == Set([after.phase.held?.id].compactMap(\.self)),
      "only the held action is unsettled", sourceLocation: sourceLocation)

    // Every deadline is armed once, disarmed by its generation, and only in its phases.
    if case .deadlineExpired(let deadline, let generation) = event,
      armed[deadline] == generation
    {
      armed[deadline] = nil
    }
    for effect in effects {
      switch effect {
      case .arm(let deadline, let duration, let generation):
        #expect(armed[deadline] == nil, "\(deadline) armed twice", sourceLocation: sourceLocation)
        #expect(generation > lastGeneration, sourceLocation: sourceLocation)
        #expect(duration == configuration.deadlines[deadline], sourceLocation: sourceLocation)
        armed[deadline] = generation
        lastGeneration = generation
      case .disarm(let deadline, let generation):
        #expect(armed[deadline] == generation, sourceLocation: sourceLocation)
        armed[deadline] = nil
      default:
        break
      }
    }
    #expect(armed == after.armed, sourceLocation: sourceLocation)
    #expect(
      Set(after.armed.keys).isSubset(of: allowedDeadlines(after.phase)),
      "\(after.armed.keys) armed in \(after.phase)", sourceLocation: sourceLocation)

    // Every path to ended emits one ended event, last, with nothing left armed or held.
    let endedCount = effects.count(where: \.isEnded)
    endedEvents += endedCount
    #expect(endedEvents <= 1, "ended emitted twice", sourceLocation: sourceLocation)
    switch (before.phase, after.phase) {
    case (.ended, _):
      #expect(after == before, "an ended call never changes", sourceLocation: sourceLocation)
      #expect(effects.allSatisfy { $0.isRefusal }, "\(effects)", sourceLocation: sourceLocation)
    case (_, .ended):
      #expect(endedCount == 1, sourceLocation: sourceLocation)
      #expect(effects.last?.isEnded == true, sourceLocation: sourceLocation)
      #expect(after.armed.isEmpty, sourceLocation: sourceLocation)
    default:
      #expect(endedCount == 0, sourceLocation: sourceLocation)
    }

    // A call preview never involves the calling framework.
    if before.phase == .previewing, after.phase == .previewing {
      #expect(
        !effects.contains { $0.involvesFramework }, "\(effects)",
        sourceLocation: sourceLocation)
    }

    // An app request is sent, refused, or carried out by the SDK, exactly once.
    if case .requested(let action) = event {
      let answers = effects.count { effect in
        switch effect {
        case .request(action), .reject(action, _): true
        default: false
        }
      }
      #expect(
        answers == 1 || (answers == 0 && after.phase != before.phase), "\(effects)",
        sourceLocation: sourceLocation)
    }
  }

  private mutating func settle(_ id: ActionID, _ sourceLocation: SourceLocation) {
    #expect(performed.contains(id), "settled an unknown action", sourceLocation: sourceLocation)
    #expect(!settled.contains(id), "settled an action twice", sourceLocation: sourceLocation)
    settled.insert(id)
  }
}

private func allowedDeadlines(_ phase: Phase) -> Set<Deadline> {
  switch phase {
  case .ringing: [.ring]
  case .requesting, .placing: [.placement]
  case .preparing: [.mediaPreparation]
  case .dialing: [.ring, .audioActivation]
  case .connecting: [.connect, .audioActivation]
  case .connected: [.audioActivation]
  case .reconnecting: [.reconnect, .audioActivation]
  case .reporting, .previewing, .ended: []
  }
}

private func isGrouped(_ effects: [Effect]) -> Bool {
  let groups = effects.map { effect in
    switch effect {
    case .fulfill, .fail: 0
    case .arm, .disarm: 1
    case .emit: 3
    default: 2
    }
  }
  return groups == groups.sorted()
}

extension Effect {
  fileprivate var isRefusal: Bool {
    switch self {
    case .fail, .reject: true
    default: false
    }
  }

  fileprivate var involvesFramework: Bool {
    switch self {
    case .reportIncoming, .request, .fulfill, .update, .reportOutgoing, .reportEnded,
      .prepareMedia:
      true
    default:
      false
    }
  }
}

/// Picks random events, weighted towards the ones that move a call on.
private struct EventSource {
  var random: SplitMix64
  var nextAction: UInt16 = 100

  mutating func event(for state: State) -> Event {
    switch Int.random(in: 0..<16, using: &random) {
    case 0, 1: return .performed(freshAction(), pick(allActions))
    case 2, 3: return .requested(pick(allActions))
    case 4: return .requestFailed(pick(allActions))
    case 5:
      return .reportCompleted(
        pick([.presented, .filtered(.doNotDisturb), .refused(.refused)]))
    case 6, 7:
      return .server(
        pick([
          .connecting, .connected, .reconnecting, .partiesChanged([alice]), .endedRemotely,
          .answeredElsewhere, .declinedElsewhere, .unanswered, .failed,
        ]))
    case 8:
      let deadline = pick(Deadline.allCases)
      let current = state.armed[deadline] ?? 0
      return .deadlineExpired(deadline, generation: pick([current, current, current + 1]))
    case 9: return .mediaPrepared
    case 10: return .mediaPreparationFailed
    case 11: return .placed
    case 12: return .audioActivated
    case 13: return .frameworkReset
    case 14: return .actionTimedOut(state.phase.held?.id ?? freshAction())
    default: return .server(pick([.connecting, .connected]))
    }
  }

  private mutating func freshAction() -> ActionID {
    nextAction += 1
    return actionID(nextAction)
  }

  private mutating func pick<Element>(_ elements: [Element]) -> Element {
    elements[Int.random(in: elements.indices, using: &random)]
  }
}

struct Walk: Sendable, CustomTestStringConvertible {
  let start: Start
  let policy: PresentationPolicy
  let configuration: VoIPConfiguration

  var testDescription: String {
    "\(start.rawValue)\(policy == noPreviews ? ", no previews" : "")"
      + "\(configuration == withMerging ? ", merging" : "")"
  }
}

let walks: [Walk] = Start.allCases.flatMap { start in
  [
    Walk(start: start, policy: PresentationPolicy(), configuration: VoIPConfiguration()),
    Walk(start: start, policy: noPreviews, configuration: withMerging),
  ]
}

@Suite struct CallMachineInvariantTests {
  @Test(arguments: walks)
  func randomWalksKeepEveryInvariant(_ walk: Walk) throws {
    let origin = try walk.start.state(policy: walk.policy, configuration: walk.configuration)
    for seed in 0..<150 {
      var source = EventSource(random: SplitMix64(state: UInt64(seed)))
      var checker = InvariantChecker(following: origin, configuration: walk.configuration)
      var state = origin
      for _ in 0..<30 {
        let event = source.event(for: state)
        let (next, effects) = CallMachine.transition(
          state, event, configuration: walk.configuration, now: later)
        checker.check(state, event, next, effects)
        state = next
      }
    }
  }

  @Test(arguments: Start.allCases.filter { !$0.rawValue.hasPrefix("reporting") && $0 != .ended })
  func endingFromAnyLivePhaseSettlesEverything(_ start: Start) throws {
    let before = try start.state()
    let (after, effects) = CallMachine.transition(
      before, .server(.endedRemotely), configuration: VoIPConfiguration(), now: later)

    #expect(after.phase == .ended(.endedRemotely))
    #expect(after.armed.isEmpty)
    #expect(effects.count(where: \.isEnded) == 1)
    #expect(effects.last == .emit(.ended(after.call)))
    for (deadline, generation) in before.armed {
      #expect(effects.contains(.disarm(deadline, generation: generation)))
    }
    if let held = before.phase.held {
      #expect(effects.filter { $0 == .fail(held.id) }.count == 1)
    }
  }

  @Test(arguments: Start.allCases, Deadline.allCases)
  func timersFromAnotherGenerationAreIgnored(_ start: Start, _ deadline: Deadline) throws {
    let before = try start.state()
    let stale = before.lastGeneration + 1
    let (after, effects) = CallMachine.transition(
      before, .deadlineExpired(deadline, generation: stale), configuration: VoIPConfiguration(),
      now: later)
    #expect(after == before)
    #expect(effects.isEmpty)
  }

  @Test func aDisarmedTimerThatFiresLateIsIgnored() throws {
    let ringing = try Start.ringing.state()
    let generation = try #require(ringing.armed[.ring])
    let (answered, _) = CallMachine.transition(
      ringing, .performed(a1, answer), configuration: VoIPConfiguration(), now: later)
    let (after, effects) = CallMachine.transition(
      answered, .deadlineExpired(.ring, generation: generation),
      configuration: VoIPConfiguration(), now: later)
    #expect(after == answered)
    #expect(effects.isEmpty)
  }
}
