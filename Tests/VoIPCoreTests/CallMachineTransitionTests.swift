import Foundation
import Testing

@testable import VoIPCore

/// One row of the state table: a starting state, one event, and the expected phase and effects.
struct TransitionRow: Sendable, CustomTestStringConvertible {
  enum Trigger: Sendable {
    case event(Event)
    /// The timer of an armed deadline fires with its current generation.
    case expiry(Deadline)
  }

  let start: Start
  let trigger: Trigger
  let phase: Phase
  let effects: [Shape]
  let policy: PresentationPolicy
  let configuration: VoIPConfiguration

  init(
    _ start: Start, _ trigger: Trigger, _ phase: Phase, _ effects: [Shape],
    policy: PresentationPolicy = PresentationPolicy(),
    configuration: VoIPConfiguration = VoIPConfiguration()
  ) {
    self.start = start
    self.trigger = trigger
    self.phase = phase
    self.effects = effects
    self.policy = policy
    self.configuration = configuration
  }

  var testDescription: String {
    "\(start.rawValue) + \(trigger) → \(phase)".replacing(/(VoIPCore|CallMachine)\./, with: "")
  }
}

let transitionRows: [TransitionRow] = [
  // MARK: Reporting an incoming call
  .init(.reporting, .event(.reportCompleted(.presented)), .ringing, [.arm(.ring), .presented]),
  .init(
    .reporting, .event(.reportCompleted(.filtered(.doNotDisturb))), .previewing,
    [.previewStarted]),
  .init(
    .reporting, .event(.reportCompleted(.filtered(.blockList))), .ended(.filtered(.blockList)),
    [.ended(.filtered(.blockList))], policy: noPreviews),
  .init(
    .reporting, .event(.reportCompleted(.refused(.atCapacity))), .ended(.failed(.atCapacity)),
    [.ended(.failed(.atCapacity))]),
  .init(
    .reporting, .event(.server(.answeredElsewhere)),
    .reporting(endOnPresent: .answeredElsewhere), []),
  .init(
    .reporting, .event(.server(.declinedElsewhere)),
    .reporting(endOnPresent: .declinedElsewhere), []),
  .init(.reporting, .event(.server(.failed)), .reporting(endOnPresent: .failed(.server)), []),
  .init(
    .reporting, .event(.server(.partiesChanged([alice]))), .reporting(endOnPresent: nil),
    [.update]),
  .init(.reporting, .event(.server(.connected)), .reporting(endOnPresent: nil), []),
  .init(.reporting, .event(.performed(a2, answer)), .reporting(endOnPresent: nil), [.fail(a2)]),
  .init(
    .reporting, .event(.requested(answer)), .reporting(endOnPresent: nil),
    [.reject(answer, .notAllowed(.ringing))]),
  .init(
    .reporting, .event(.requested(end)), .reporting(endOnPresent: nil),
    [.reject(end, .notAllowed(.ringing))]),
  .init(
    .reporting, .event(.frameworkReset), .ended(.failed(.frameworkReset)),
    [.ended(.failed(.frameworkReset))]),

  // MARK: A server event that arrived while reporting
  .init(
    .reportingAnsweredElsewhere, .event(.reportCompleted(.presented)), .previewing,
    [.reportEnded(.answeredElsewhere), .previewStarted]),
  .init(
    .reportingAnsweredElsewhere, .event(.reportCompleted(.presented)), .ended(.answeredElsewhere),
    [.reportEnded(.answeredElsewhere), .ended(.answeredElsewhere)], policy: noPreviews),
  .init(
    .reportingAnsweredElsewhere, .event(.reportCompleted(.filtered(.doNotDisturb))), .previewing,
    [.previewStarted]),
  .init(
    .reportingAnsweredElsewhere, .event(.reportCompleted(.refused(.refused))),
    .ended(.answeredElsewhere), [.ended(.answeredElsewhere)], policy: noPreviews),
  .init(
    .reportingAnsweredElsewhere, .event(.server(.endedRemotely)),
    .reporting(endOnPresent: .endedRemotely), []),
  .init(
    .reportingEndedRemotely, .event(.reportCompleted(.presented)), .ended(.endedRemotely),
    [.reportEnded(.endedRemotely), .ended(.endedRemotely)]),
  .init(
    .reportingEndedRemotely, .event(.reportCompleted(.filtered(.doNotDisturb))),
    .ended(.endedRemotely), [.ended(.endedRemotely)]),

  // MARK: Ringing
  .init(
    .ringing, .event(.performed(a2, answer)), .preparing(held(a2, answer)),
    [.disarm(.ring), .arm(.mediaPreparation), .prepareMedia]),
  .init(
    .ringing, .event(.performed(a2, end)), .ended(.endedHere),
    [.fulfill(a2), .disarm(.ring), .performed(end), .ended(.endedHere)]),
  .init(.ringing, .event(.performed(a2, muteOn)), .ringing, [.fail(a2)]),
  .init(.ringing, .event(.performed(a2, join)), .ringing, [.fail(a2)]),
  .init(.ringing, .event(.requested(answer)), .ringing, [.request(answer)]),
  .init(.ringing, .event(.requested(end)), .ringing, [.request(end)]),
  .init(.ringing, .event(.requested(join)), .ringing, [.reject(join, .notAllowed(.ringing))]),
  .init(.ringing, .event(.requested(muteOn)), .ringing, [.reject(muteOn, .notAllowed(.ringing))]),
  .init(
    .ringing, .event(.requested(startAction)), .ringing,
    [.reject(startAction, .notAllowed(.ringing))]),
  .init(
    .ringing, .event(.server(.answeredElsewhere)), .previewing,
    [.disarm(.ring), .reportEnded(.answeredElsewhere), .previewStarted]),
  .init(
    .ringing, .event(.server(.answeredElsewhere)), .ended(.answeredElsewhere),
    [.disarm(.ring), .reportEnded(.answeredElsewhere), .ended(.answeredElsewhere)],
    policy: noPreviews),
  .init(
    .ringing, .event(.server(.declinedElsewhere)), .ended(.declinedElsewhere),
    [.disarm(.ring), .reportEnded(.declinedElsewhere), .ended(.declinedElsewhere)]),
  .init(
    .ringing, .event(.server(.endedRemotely)), .ended(.endedRemotely),
    [.disarm(.ring), .reportEnded(.endedRemotely), .ended(.endedRemotely)]),
  .init(
    .ringing, .event(.server(.unanswered)), .ended(.unanswered),
    [.disarm(.ring), .reportEnded(.unanswered), .ended(.unanswered)]),
  .init(
    .ringing, .event(.server(.failed)), .ended(.failed(.server)),
    [.disarm(.ring), .reportEnded(.failed(.server)), .ended(.failed(.server))]),
  .init(.ringing, .event(.server(.partiesChanged([alice]))), .ringing, [.update]),
  .init(.ringing, .event(.server(.connected)), .ringing, []),
  .init(
    .ringing, .expiry(.ring), .ended(.unanswered),
    [.reportEnded(.unanswered), .ended(.unanswered)]),
  .init(
    .ringing, .event(.frameworkReset), .ended(.failed(.frameworkReset)),
    [.disarm(.ring), .ended(.failed(.frameworkReset))]),
  .init(.ringing, .event(.actionTimedOut(a2)), .ringing, []),
  .init(.ringing, .event(.audioActivated), .ringing, []),

  // MARK: Previewing
  .init(
    .previewing, .event(.requested(join)), .requesting(join),
    [.arm(.placement), .request(join)]),
  .init(
    .previewing, .event(.requested(end)), .ended(.endedHere),
    [.performed(end), .ended(.endedHere)]),
  .init(
    .previewing, .event(.requested(answer)), .previewing,
    [.reject(answer, .notAllowed(.previewing))]),
  .init(
    .previewing, .event(.requested(muteOn)), .previewing,
    [.reject(muteOn, .notAllowed(.previewing))]),
  .init(.previewing, .event(.performed(a2, join)), .previewing, [.fail(a2)]),
  .init(.previewing, .event(.performed(a2, end)), .previewing, [.fail(a2)]),
  .init(.previewing, .event(.server(.answeredElsewhere)), .previewing, []),
  .init(
    .previewing, .event(.server(.endedRemotely)), .ended(.endedRemotely),
    [.ended(.endedRemotely)]),
  .init(
    .previewing, .event(.server(.declinedElsewhere)), .ended(.declinedElsewhere),
    [.ended(.declinedElsewhere)]),
  .init(
    .previewing, .event(.server(.unanswered)), .ended(.unanswered), [.ended(.unanswered)]),
  .init(.previewing, .event(.server(.partiesChanged([alice]))), .previewing, []),
  .init(.previewing, .event(.server(.connected)), .previewing, []),
  .init(.previewing, .event(.frameworkReset), .previewing, []),

  // MARK: Requesting a start
  .init(
    .requestingStart, .event(.performed(a2, startAction)), .placing(held(a2, startAction)),
    [.startRequested]),
  .init(.requestingStart, .event(.performed(a2, join)), .requesting(startAction), [.fail(a2)]),
  .init(
    .requestingStart, .event(.requestFailed(startAction)), .ended(.failed(.refused)),
    [.disarm(.placement), .ended(.failed(.refused))]),
  .init(.requestingStart, .event(.requestFailed(end)), .requesting(startAction), []),
  .init(
    .requestingStart, .expiry(.placement), .ended(.failed(.notPlaced)),
    [.reportEnded(.failed(.notPlaced)), .ended(.failed(.notPlaced))]),
  .init(.requestingStart, .event(.requested(end)), .requesting(startAction), [.request(end)]),
  .init(
    .requestingStart, .event(.requested(muteOn)), .requesting(startAction),
    [.reject(muteOn, .notAllowed(.dialing))]),
  .init(.requestingStart, .event(.performed(a2, end)), .requesting(startAction), [.fail(a2)]),
  .init(
    .requestingStart, .event(.server(.endedRemotely)), .ended(.endedRemotely),
    [.disarm(.placement), .reportEnded(.endedRemotely), .ended(.endedRemotely)]),
  .init(.requestingStart, .event(.placed), .requesting(startAction), []),
  .init(
    .requestingStart, .event(.frameworkReset), .ended(.failed(.frameworkReset)),
    [.disarm(.placement), .ended(.failed(.frameworkReset))]),

  // MARK: Requesting a join
  .init(.requestingJoin, .event(.performed(a2, join)), .placing(held(a2, join)), [.joinRequested]),
  .init(.requestingJoin, .event(.performed(a2, startAction)), .requesting(join), [.fail(a2)]),
  .init(
    .requestingJoin, .event(.requestFailed(join)), .previewing,
    [.disarm(.placement), .previewStarted]),
  .init(
    .requestingJoin, .expiry(.placement), .previewing,
    [.reportEnded(.failed(.notPlaced)), .previewStarted]),
  .init(.requestingJoin, .event(.server(.answeredElsewhere)), .requesting(join), []),
  .init(
    .requestingJoin, .event(.server(.endedRemotely)), .ended(.endedRemotely),
    [.disarm(.placement), .reportEnded(.endedRemotely), .ended(.endedRemotely)]),
  .init(
    .requestingJoin, .event(.frameworkReset), .previewing,
    [.disarm(.placement), .previewStarted]),

  // MARK: Placing a started call
  .init(
    .placingStart, .event(.placed), .preparing(held(a1, startAction)),
    [.disarm(.placement), .arm(.mediaPreparation), .prepareMedia]),
  .init(
    .placingStart, .expiry(.placement), .ended(.failed(.notPlaced)),
    [.fail(a1), .reportEnded(.failed(.notPlaced)), .ended(.failed(.notPlaced))]),
  .init(
    .placingStart, .event(.performed(a2, end)), .ended(.endedHere),
    [.fail(a1), .fulfill(a2), .disarm(.placement), .performed(end), .ended(.endedHere)]),
  .init(
    .placingStart, .event(.actionTimedOut(a1)), .ended(.failed(.actionTimedOut)),
    [
      .fail(a1), .disarm(.placement), .reportEnded(.failed(.actionTimedOut)),
      .ended(.failed(.actionTimedOut)),
    ]),
  .init(.placingStart, .event(.actionTimedOut(a2)), .placing(held(a1, startAction)), []),
  .init(
    .placingStart, .event(.frameworkReset), .ended(.failed(.frameworkReset)),
    [.fail(a1), .disarm(.placement), .ended(.failed(.frameworkReset))]),
  .init(
    .placingStart, .event(.performed(a2, muteOn)), .placing(held(a1, startAction)),
    [.fulfill(a2), .performed(muteOn)]),
  .init(
    .placingStart, .event(.performed(a2, holdOn)), .placing(held(a1, startAction)), [.fail(a2)],
    configuration: withoutCapabilities),
  .init(.placingStart, .event(.server(.connected)), .placing(held(a1, startAction)), []),
  .init(.placingStart, .event(.requested(end)), .placing(held(a1, startAction)), [.request(end)]),
  .init(.placingStart, .event(.mediaPrepared), .placing(held(a1, startAction)), []),

  // MARK: Placing a joined call
  .init(
    .placingJoin, .event(.placed), .preparing(held(a1, join)),
    [.disarm(.placement), .arm(.mediaPreparation), .prepareMedia]),
  .init(
    .placingJoin, .expiry(.placement), .previewing,
    [.fail(a1), .reportEnded(.failed(.notPlaced)), .previewStarted]),
  .init(
    .placingJoin, .event(.performed(a2, end)), .previewing,
    [.fail(a1), .fulfill(a2), .disarm(.placement), .previewStarted]),
  .init(
    .placingJoin, .event(.frameworkReset), .previewing,
    [.fail(a1), .disarm(.placement), .previewStarted]),
  .init(
    .placingJoin, .event(.actionTimedOut(a1)), .previewing,
    [.fail(a1), .disarm(.placement), .reportEnded(.failed(.actionTimedOut)), .previewStarted]),
  .init(
    .placingJoin, .event(.server(.endedRemotely)), .ended(.endedRemotely),
    [.fail(a1), .disarm(.placement), .reportEnded(.endedRemotely), .ended(.endedRemotely)]),

  // MARK: Preparing media for an answer
  .init(
    .preparingAnswer, .event(.mediaPrepared), .connecting,
    [
      .fulfill(a1), .disarm(.mediaPreparation), .arm(.audioActivation), .arm(.connect),
      .performed(answer),
    ]),
  .init(
    .preparingAnswer, .event(.mediaPreparationFailed), .ended(.failed(.media)),
    [
      .fail(a1), .disarm(.mediaPreparation), .reportEnded(.failed(.media)),
      .ended(.failed(.media)),
    ]),
  .init(
    .preparingAnswer, .expiry(.mediaPreparation), .ended(.failed(.media)),
    [.fail(a1), .reportEnded(.failed(.media)), .ended(.failed(.media))]),
  .init(
    .preparingAnswer, .event(.server(.answeredElsewhere)), .previewing,
    [.fail(a1), .disarm(.mediaPreparation), .reportEnded(.answeredElsewhere), .previewStarted]),
  .init(
    .preparingAnswer, .event(.performed(a2, end)), .ended(.endedHere),
    [.fail(a1), .fulfill(a2), .disarm(.mediaPreparation), .performed(end), .ended(.endedHere)]),
  .init(
    .preparingAnswer, .event(.performed(a2, answer)), .preparing(held(a1, answer)), [.fail(a2)]),
  .init(
    .preparingAnswer, .event(.actionTimedOut(a1)), .ended(.failed(.actionTimedOut)),
    [
      .fail(a1), .disarm(.mediaPreparation), .reportEnded(.failed(.actionTimedOut)),
      .ended(.failed(.actionTimedOut)),
    ]),

  // MARK: Preparing media for a start
  .init(
    .preparingStart, .event(.mediaPrepared), .dialing,
    [
      .fulfill(a1), .disarm(.mediaPreparation), .arm(.audioActivation), .arm(.ring),
      .reportOutgoing(connected: false), .performed(startAction),
    ]),
  .init(
    .preparingStart, .event(.mediaPreparationFailed), .ended(.failed(.media)),
    [
      .fail(a1), .disarm(.mediaPreparation), .reportEnded(.failed(.media)),
      .ended(.failed(.media)),
    ]),
  .init(
    .preparingStart, .event(.server(.answeredElsewhere)), .preparing(held(a1, startAction)), []),
  .init(
    .preparingStartConnected, .event(.mediaPrepared), .connected,
    [
      .fulfill(a1), .disarm(.mediaPreparation), .arm(.audioActivation),
      .reportOutgoing(connected: false), .reportOutgoing(connected: true), .performed(startAction),
    ]),

  // MARK: Preparing media for a join
  .init(
    .preparingJoin, .event(.mediaPrepared), .connecting,
    [
      .fulfill(a1), .disarm(.mediaPreparation), .arm(.audioActivation), .arm(.connect),
      .reportOutgoing(connected: false), .performed(join),
    ]),
  .init(
    .preparingJoin, .event(.mediaPreparationFailed), .previewing,
    [.fail(a1), .disarm(.mediaPreparation), .reportEnded(.failed(.media)), .previewStarted]),
  .init(
    .preparingJoin, .expiry(.mediaPreparation), .previewing,
    [.fail(a1), .reportEnded(.failed(.media)), .previewStarted]),

  // MARK: Dialing
  .init(.dialing, .event(.server(.connecting)), .connecting, [.disarm(.ring), .arm(.connect)]),
  .init(
    .dialing, .event(.server(.connected)), .connected,
    [.disarm(.ring), .reportOutgoing(connected: true)]),
  .init(
    .dialing, .expiry(.ring), .ended(.unanswered),
    [.disarm(.audioActivation), .reportEnded(.unanswered), .ended(.unanswered)]),
  .init(.dialing, .event(.audioActivated), .dialing, [.disarm(.audioActivation)]),
  .init(
    .dialing, .expiry(.audioActivation), .ended(.failed(.audioActivationTimedOut)),
    [
      .disarm(.ring), .reportEnded(.failed(.audioActivationTimedOut)),
      .ended(.failed(.audioActivationTimedOut)),
    ]),
  .init(.dialing, .event(.performed(a2, tones)), .dialing, [.fulfill(a2), .performed(tones)]),
  .init(
    .dialing, .event(.server(.unanswered)), .ended(.unanswered),
    [
      .disarm(.ring), .disarm(.audioActivation), .reportEnded(.unanswered),
      .ended(.unanswered),
    ]),
  .init(.dialing, .event(.server(.answeredElsewhere)), .dialing, []),
  .init(
    .dialing, .event(.performed(a2, end)), .ended(.endedHere),
    [
      .fulfill(a2), .disarm(.ring), .disarm(.audioActivation), .performed(end),
      .ended(.endedHere),
    ]),

  // MARK: Connecting
  .init(.connectingAnswer, .event(.server(.connected)), .connected, [.disarm(.connect)]),
  .init(
    .connectingAnswer, .expiry(.connect), .ended(.failed(.connectTimedOut)),
    [
      .disarm(.audioActivation), .reportEnded(.failed(.connectTimedOut)),
      .ended(.failed(.connectTimedOut)),
    ]),
  .init(
    .connectingAnswer, .event(.server(.answeredElsewhere)), .previewing,
    [
      .disarm(.audioActivation), .disarm(.connect), .reportEnded(.answeredElsewhere),
      .previewStarted,
    ]),
  .init(
    .connectingAnswer, .event(.server(.answeredElsewhere)), .ended(.answeredElsewhere),
    [
      .disarm(.audioActivation), .disarm(.connect), .reportEnded(.answeredElsewhere),
      .ended(.answeredElsewhere),
    ], policy: noPreviews),
  .init(.connectingAnswer, .event(.audioActivated), .connecting, [.disarm(.audioActivation)]),
  .init(.connectingAnswer, .event(.server(.reconnecting)), .connecting, []),
  .init(
    .connectingStart, .event(.server(.connected)), .connected,
    [.disarm(.connect), .reportOutgoing(connected: true)]),
  .init(
    .connectingJoin, .event(.server(.connected)), .connected,
    [.disarm(.connect), .reportOutgoing(connected: true)]),
  .init(.connectingJoin, .event(.server(.answeredElsewhere)), .connecting, []),
  .init(
    .connectingJoin, .event(.performed(a2, end)), .ended(.endedHere),
    [
      .fulfill(a2), .disarm(.audioActivation), .disarm(.connect), .performed(end),
      .ended(.endedHere),
    ]),

  // MARK: Connected
  .init(.connected, .event(.server(.reconnecting)), .reconnecting, [.arm(.reconnect)]),
  .init(
    .connected, .event(.performed(a2, holdOn)), .connected, [.fulfill(a2), .performed(holdOn)]),
  .init(
    .connected, .event(.performed(a2, holdOn)), .connected, [.fail(a2)],
    configuration: withoutCapabilities),
  .init(.connected, .event(.performed(a2, tones)), .connected, [.fulfill(a2), .performed(tones)]),
  .init(.connected, .event(.performed(a2, merge)), .connected, [.fail(a2)]),
  .init(
    .connected, .event(.performed(a2, merge)), .connected, [.fulfill(a2), .performed(merge)],
    configuration: withMerging),
  .init(
    .connected, .event(.performed(a2, unmerge)), .connected,
    [.fulfill(a2), .performed(unmerge)], configuration: withMerging),
  .init(.connected, .event(.requested(holdOn)), .connected, [.request(holdOn)]),
  .init(
    .connected, .event(.requested(holdOn)), .connected, [.reject(holdOn, .unsupported)],
    configuration: withoutCapabilities),
  .init(
    .connected, .event(.requested(tones)), .connected, [.reject(tones, .unsupported)],
    configuration: withoutCapabilities),
  .init(.connected, .event(.requested(merge)), .connected, [.reject(merge, .unsupported)]),
  .init(
    .connected, .event(.requested(merge)), .connected, [.request(merge)],
    configuration: withMerging),
  .init(.connected, .event(.requested(muteOn)), .connected, [.request(muteOn)]),
  .init(
    .connected, .event(.requested(answer)), .connected,
    [.reject(answer, .notAllowed(.connected))]),
  .init(
    .connected, .event(.requested(join)), .connected, [.reject(join, .notAllowed(.connected))]),
  .init(
    .connected, .event(.performed(a2, end)), .ended(.endedHere),
    [.fulfill(a2), .performed(end), .ended(.endedHere)]),
  .init(
    .connected, .event(.server(.endedRemotely)), .ended(.endedRemotely),
    [.reportEnded(.endedRemotely), .ended(.endedRemotely)]),
  .init(.connected, .event(.server(.answeredElsewhere)), .connected, []),
  .init(.connected, .event(.server(.connected)), .connected, []),
  .init(
    .connected, .event(.frameworkReset), .ended(.failed(.frameworkReset)),
    [.ended(.failed(.frameworkReset))]),

  // MARK: Reconnecting
  .init(.reconnecting, .event(.server(.connected)), .connected, [.disarm(.reconnect)]),
  .init(
    .reconnecting, .expiry(.reconnect), .ended(.failed(.reconnectTimedOut)),
    [.reportEnded(.failed(.reconnectTimedOut)), .ended(.failed(.reconnectTimedOut))]),
  .init(
    .reconnecting, .event(.performed(a2, muteOn)), .reconnecting,
    [.fulfill(a2), .performed(muteOn)]),
  .init(.reconnecting, .event(.server(.reconnecting)), .reconnecting, []),

  // MARK: Ended
  .init(.ended, .event(.performed(a2, end)), .ended(.endedRemotely), [.fail(a2)]),
  .init(
    .ended, .event(.requested(end)), .ended(.endedRemotely),
    [.reject(end, .notAllowed(.ended(.endedRemotely)))]),
  .init(.ended, .event(.server(.connected)), .ended(.endedRemotely), []),
  .init(.ended, .event(.frameworkReset), .ended(.endedRemotely), []),
  .init(.ended, .event(.reportCompleted(.presented)), .ended(.endedRemotely), []),
  .init(.ended, .event(.server(.partiesChanged([alice]))), .ended(.endedRemotely), []),
]

struct BeginRow: Sendable, CustomTestStringConvertible {
  let name: String
  let origin: CallMachine.Origin
  var configuration = VoIPConfiguration()
  let phase: Phase?
  let effects: [Shape]

  var testDescription: String { name }
}

let previewByDefault = VoIPConfiguration(presentationPolicy: PresentationPolicy(incoming: .preview))

let beginRows: [BeginRow] = [
  BeginRow(
    name: "an incoming call rings by default",
    origin: .incoming(IncomingCall(id: callID, parties: [alice])),
    phase: .reporting(endOnPresent: nil), effects: [.reportIncoming]),
  BeginRow(
    name: "a call's policy previews it",
    origin: .incoming(incoming(.preview, policy: PresentationPolicy())),
    phase: .previewing, effects: [.previewStarted]),
  BeginRow(
    name: "the configuration's policy previews a call",
    origin: .incoming(IncomingCall(id: callID, parties: [alice])),
    configuration: previewByDefault, phase: .previewing, effects: [.previewStarted]),
  BeginRow(
    name: "a call's policy overrides the configuration's",
    origin: .incoming(incoming(.ring, policy: PresentationPolicy())),
    configuration: previewByDefault, phase: .reporting(endOnPresent: nil),
    effects: [.reportIncoming]),
  BeginRow(
    name: "a call presented nowhere doesn't exist here",
    origin: .incoming(incoming(.none, policy: PresentationPolicy())), phase: nil, effects: []),
  BeginRow(
    name: "the app starts an outgoing call",
    origin: .outgoing(outgoing),
    phase: .requesting(startAction), effects: [.arm(.placement), .request(startAction)]),
  BeginRow(
    name: "the system starts an outgoing call",
    origin: .systemStart(a1, outgoing),
    phase: .placing(held(a1, startAction)), effects: [.arm(.placement), .startRequested]),
]

@Suite struct CallMachineTransitionTests {
  @Test(arguments: beginRows)
  func begin(_ row: BeginRow) {
    let result = CallMachine.begin(row.origin, configuration: row.configuration, now: epoch)
    #expect(result?.0.phase == row.phase)
    #expect(result?.0.call.status == row.phase?.status)
    #expect((result?.1 ?? []).map(Shape.init) == row.effects)
  }

  @Test(arguments: transitionRows)
  func transition(_ row: TransitionRow) throws {
    let before = try row.start.state(policy: row.policy, configuration: row.configuration)
    let event: Event
    switch row.trigger {
    case .event(let rowEvent):
      event = rowEvent
    case .expiry(let deadline):
      let generation = try #require(before.armed[deadline], "\(deadline) isn't armed")
      event = .deadlineExpired(deadline, generation: generation)
    }

    let (after, effects) = CallMachine.transition(
      before, event, configuration: row.configuration, now: later)

    #expect(after.phase == row.phase)
    #expect(after.call.status == row.phase.status)
    #expect(effects.map(Shape.init) == row.effects)
  }

  @Test func everyStartingStateIsCovered() {
    let covered = Set(transitionRows.map(\.start))
    #expect(covered == Set(Start.allCases))
  }

  @Test func answeringRecordsWhenTheUserAnswered() throws {
    let ringing = try Start.ringing.state()
    let (preparing, _) = CallMachine.transition(
      ringing, .performed(a1, answer), configuration: VoIPConfiguration(), now: later)
    #expect(preparing.call.answeredAt == later)
  }

  @Test func connectingRecordsTheFirstConnectionOnly() throws {
    let connecting = try Start.connectingAnswer.state()
    let configuration = VoIPConfiguration()
    var (state, _) = CallMachine.transition(
      connecting, .server(.connected), configuration: configuration, now: later)
    #expect(state.call.connectedAt == later)

    for event: Event in [.server(.reconnecting), .server(.connected)] {
      (state, _) = CallMachine.transition(
        state, event, configuration: configuration, now: later.addingTimeInterval(60))
    }
    #expect(state.phase == .connected)
    #expect(state.call.connectedAt == later)
  }

  @Test func performedActionsUpdateTheCall() throws {
    let configuration = VoIPConfiguration()
    var (state, effects) = CallMachine.transition(
      try Start.connected.state(), .performed(a1, muteOn), configuration: configuration,
      now: later)
    #expect(state.call.isMuted)
    #expect(effects.last == .emit(.performed(muteOn, state.call)))

    (state, effects) = CallMachine.transition(
      state, .performed(a2, holdOn), configuration: configuration, now: later)
    #expect(state.call.isOnHold)
    #expect(effects.last == .emit(.performed(holdOn, state.call)))
  }

  @Test func partiesChangeTheCall() throws {
    let bob = try Party(handle: Handle(kind: .generic, value: "bob"))
    let (state, effects) = CallMachine.transition(
      try Start.connected.state(), .server(.partiesChanged([alice, bob])),
      configuration: VoIPConfiguration(), now: later)
    #expect(state.call.parties == [alice, bob])
    #expect(effects == [.update(state.call)])
  }

  @Test func deadlinesUseTheConfiguredDurations() throws {
    let configuration = VoIPConfiguration(deadlines: Deadlines(ring: .seconds(45)))
    let reporting = try Start.reporting.state(configuration: configuration)
    let (ringing, effects) = CallMachine.transition(
      reporting, .reportCompleted(.presented), configuration: configuration, now: later)
    let generation = try #require(ringing.armed[.ring])
    #expect(effects.first == .arm(.ring, after: .seconds(45), generation: generation))
  }
}
