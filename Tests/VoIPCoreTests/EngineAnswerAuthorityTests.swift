import Testing
import VoIPTesting

@testable import VoIPCore

@Suite(.timeLimit(.minutes(1)))
@VoIPActor
struct EngineAnswerAuthorityTests {
  @Test func aDelayedNativeReceiptUsesItsOriginalClaimDeadline() async throws {
    let rig = AnswerRig(claim: .allow(.init(id: "permit")))
    defer { rig.engine.close() }
    rig.invite(callID)
    rig.framework.send(.performAnswer(a1, callID, remaining: .seconds(20), elapsed: .seconds(2)))
    #expect(rig.engine.timeUntilNextDeadline == .milliseconds(500))
    let claim = try #require(rig.engine.answerTask(callID))
    await claim.value
    await rig.engine.synchronize()
    #expect(rig.authority.claims.first?.actionID == a1)
    #expect(rig.authority.claims.first?.remaining == .milliseconds(500))
    #expect(rig.status(callID) == .connecting)
    #expect(rig.framework.records.count { $0 == .fulfill(a1) } == 1)
  }

  @Test func aRefusedReceiptCannotClaimEvenAfterTheSlotFrees() async throws {
    let rig = AnswerRig(claim: .allow(.init(id: "permit")))
    defer { rig.engine.close() }
    rig.invite(callID)
    rig.invite(otherCallID)
    rig.framework.send(.performAnswer(a1, callID, remaining: .seconds(30)))
    let first = try #require(rig.engine.answerTask(callID))
    await first.value
    await rig.engine.synchronize()

    let waiting = FrameworkEvent.performAnswer(a2, otherCallID, remaining: .seconds(30))
    rig.framework.send(waiting)
    #expect(rig.status(otherCallID) == .ringing)
    #expect(rig.framework.records.count { $0 == .fail(a2) } == 1)
    _ = try rig.engine.end(callID)
    rig.framework.send(waiting)
    #expect(rig.framework.records.count { $0 == .fail(a2) } == 1)
    #expect(rig.engine.answerTask(otherCallID) == nil)
    #expect(rig.status(otherCallID) == .ringing)
  }

  @Test func aPendingClaimReservesAcrossLinesAndRefusalReleasesIt() async throws {
    let delay: Duration = .seconds(1)
    let rig = AnswerRig(claim: .refuse(.notAllowed), delayClaim: delay)
    defer { rig.engine.close() }
    rig.invite(callID, on: try callingLine("personal", label: "Personal"))
    rig.invite(otherCallID, on: try callingLine("work", label: "Work"))

    try await rig.engine.request(.answer(callID))
    let claim = try #require(rig.engine.answerTask(callID))
    try await rig.clock.waitForSleepers(count: 3)
    #expect(rig.engine.participating == [callID])
    await #expect(throws: ActionError.noParticipationSlot) {
      try await rig.engine.request(.answer(otherCallID))
    }
    #expect(rig.authority.claims.map(\.call.id) == [callID])
    #expect(rig.status(otherCallID) == .ringing)

    rig.clock.advance(by: delay)
    await claim.value
    #expect(rig.engine.participating.isEmpty)
    try await rig.engine.request(.answer(otherCallID))
    #expect(rig.engine.answerTask(otherCallID) != nil)
    #expect(rig.engine.participating == [otherCallID])
  }

  @Test func aLateClaimCannotReleaseTheGrantAdoptedByReconciliation() async throws {
    let permit = AnswerPermit(id: "shared")
    let rig = AnswerRig(claim: .allow(permit), delayClaim: .milliseconds(2600))
    defer { rig.engine.close() }
    rig.invite(callID)
    rig.framework.send(.performAnswer(a1, callID, remaining: .seconds(30)))
    let claim = try #require(rig.engine.answerTask(callID))
    try await rig.clock.waitForSleepers(count: 2)
    rig.clock.advance(by: .milliseconds(2500))
    await rig.engine.synchronize()
    await rig.engine.answerTask(callID, reconciling: true)?.value
    await rig.engine.synchronize()
    #expect(rig.status(callID) == .connecting)
    #expect(rig.authority.reconciliations.first?.actionID == a1)

    rig.clock.advance(by: .milliseconds(100))
    await claim.value
    #expect(rig.authority.releases.isEmpty)
    #expect(rig.framework.records.count { $0 == .fulfill(a1) } == 1)
  }

  @Test func aShorterNativeDeadlineCapsPreparationBeforeTheSettlementReserve() async throws {
    let rig = AnswerRig(claim: .allow(.init(id: "permit")))
    defer { rig.engine.close() }
    rig.media.preparation = .wait
    rig.invite(callID)
    rig.framework.send(
      .performAnswer(
        a1, callID, remaining: .milliseconds(1700), elapsed: .seconds(2)))
    let claim = try #require(rig.engine.answerTask(callID))
    await claim.value
    rig.framework.send(.audioActivated)
    #expect(!rig.media.records.contains(.activate))
    #expect(rig.status(callID) == .ringing)
    #expect(rig.engine.timeUntilNextDeadline == .milliseconds(1200))
    rig.clock.advance(by: .milliseconds(1199))
    #expect(!rig.framework.records.contains(.fail(a1)))
    rig.clock.advance(by: .milliseconds(1))
    await rig.engine.synchronize()
    #expect(rig.status(callID) == .ended(.failed(.media)))
    #expect(rig.framework.records.count { $0 == .fail(a1) } == 1)
    #expect(!rig.framework.records.contains(.fulfill(a1)))
  }

  @Test func budgetNeedsPositiveWholeMillisecondsAndTimeForPreparation() {
    #expect(AnswerBudget.standard.isValid(effectiveDeadline: .milliseconds(4500)))
    #expect(!AnswerBudget.standard.isValid(effectiveDeadline: .milliseconds(4499)))
    #expect(
      !AnswerBudget(
        total: .milliseconds(3500), claim: .milliseconds(2500),
        reconciliation: .milliseconds(500), settlementReserve: .milliseconds(500)
      ).isValid(effectiveDeadline: .seconds(30)))
    #expect(
      !AnswerBudget(
        total: .milliseconds(4500), claim: .microseconds(999),
        reconciliation: .milliseconds(500), settlementReserve: .milliseconds(500)
      ).isValid(effectiveDeadline: .seconds(30)))
  }
}

@VoIPActor
private final class AnswerRig {
  let clock = TestClock()
  let framework = FakeCallingFramework()
  let push = FakePushSource()
  let media = FakeMedia()
  let authority: AnswerProbe
  let engine: SpecEngine

  init(claim: AnswerDecision, delayClaim: Duration = .zero) {
    authority = AnswerProbe(clock: clock, decision: claim, delayClaim: delayClaim)
    engine = SpecEngine(
      framework: framework, media: media, push: push, configuration: VoIPConfiguration(),
      clock: clock, authority: authority, observe: { _ in })
  }

  func invite(_ id: CallID, on line: CallingLine = .default) {
    push.deliver(
      .incoming(
        IncomingCall(id: id, parties: [alice], line: line), eventID: EventID(rawValue: id.rawValue))
    )
  }

  func status(_ id: CallID) -> CallStatus? {
    engine.calls.first { $0.id == id }?.status
  }
}

@VoIPActor
private final class AnswerProbe: AnswerAuthority {
  let clock: TestClock
  let decision: AnswerDecision
  let delayClaim: Duration
  private(set) var claims: [AnswerRequest] = []
  private(set) var reconciliations: [AnswerRequest] = []
  private(set) var releases: [AnswerPermit] = []

  init(clock: TestClock, decision: AnswerDecision, delayClaim: Duration) {
    self.clock = clock
    self.decision = decision
    self.delayClaim = delayClaim
  }

  func claim(_ request: AnswerRequest) async -> AnswerDecision {
    claims.append(request)
    if delayClaim > .zero { try? await clock.sleep(for: delayClaim) }
    return decision
  }

  func reconcile(_ request: AnswerRequest) async -> AnswerDecision? {
    reconciliations.append(request)
    return decision
  }

  func release(_ permit: AnswerPermit, for request: AnswerRequest) async {
    releases.append(permit)
  }
}
