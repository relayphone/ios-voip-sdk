import CKSimProtocol
import Foundation
import Testing

@testable import CKSimRuntime

/// How the runtime decides an incoming report's outcome, applies faults and times actions.
struct RuntimePolicyTests {
  private static let filters: [(IncomingFilterReason, Int, String)] = [
    (.doNotDisturb, 3, "verified"), (.restrictedSharingMode, 5, "unverified"),
    (.callIsProtected, 6, "unverified"), (.sensitiveParticipants, 7, "unverified"),
  ]

  @Test(arguments: filters)
  func aFilteredReportFailsWithTheFiltersCodeAfterItsDelay(
    reason: IncomingFilterReason, code: Int, verification: String
  ) throws {
    let policy = try #require(behaviorProfile().incomingFilterPolicies[reason.rawValue])
    #expect(reason.code == code && policy.code == code)
    #expect(policy.delaySeconds == 2.07 && policy.verification == verification)
    #expect(!policy.evidence.isEmpty)

    let outcome = IncomingReportOutcome(
      reason: reason, duplicate: false, policy: policy, normalDelaySeconds: 0.02,
      extraDelaySeconds: 0.4)
    #expect(outcome.code == code && outcome.domain == "com.apple.CallKit.error.incomingcall")
    #expect(outcome.filterReason == reason.rawValue && outcome.verification == verification)
    #expect(abs(outcome.delaySeconds - 2.47) < 0.00001)
    let error = try #require(outcome.error)
    #expect(error.code == code && error.domain == outcome.domain)

    let duplicate = IncomingReportOutcome(
      reason: reason, duplicate: true, policy: policy, normalDelaySeconds: 0.02,
      extraDelaySeconds: 0)
    #expect(duplicate.code == 2 && duplicate.delaySeconds == 0.02, "A duplicate UUID wins")
    #expect(duplicate.filterReason == "none" && duplicate.verification == "not-applicable")
  }

  @Test func anUnfilteredReportSucceeds() {
    let outcome = IncomingReportOutcome(
      reason: .none, duplicate: false, policy: nil, normalDelaySeconds: 0.02, extraDelaySeconds: 0)
    #expect(outcome.error == nil && outcome.code == 0 && outcome.domain.isEmpty)
    #expect(outcome.delaySeconds == 0.02)
  }

  @Test func theBlockListDoesNotFilterReports() throws {
    #expect(IncomingFilterReason(rawValue: "block-list") == nil)
    #expect(try behaviorProfile().incomingFilterPolicies["block-list"] == nil)
    #expect(IncomingFilterReason(rawValue: "garbage") == nil)
  }

  @Test func anInjectedErrorUsesCodeFourWithTheNormalDelay() throws {
    let fault = IncomingReportOutcome(
      reason: .none, duplicate: false, policy: nil, normalDelaySeconds: 0.02,
      extraDelaySeconds: 0.4, incomingErrorCode: 4)
    #expect(fault.code == 4 && fault.filterReason == "none")
    #expect(fault.verification == "injected-fault")
    #expect(abs(fault.delaySeconds - 0.42) < 0.00001)
    let duplicate = IncomingReportOutcome(
      reason: .doNotDisturb, duplicate: true,
      policy: try behaviorProfile().incomingFilterPolicies["do-not-disturb"],
      normalDelaySeconds: 0.02, extraDelaySeconds: 0, incomingErrorCode: 4)
    #expect(duplicate.code == 2 && duplicate.verification == "not-applicable")
  }

  @Test func faultChangesKeepTheOtherFaults() {
    var faults = RuntimeFaults()
    faults.apply([.staleAudio(true), .reportCallbackDelayMS(5000), .invalidateDuringHandoff(true)])
    faults.apply([.incomingErrorCode(4)])
    #expect(faults.staleAudio == true && faults.reportCallbackDelayMS == 5000)
    #expect(faults.invalidateDuringHandoff == true && faults.incomingErrorCode == 4)
    faults.apply([.incomingErrorCode(0)])
    #expect(faults.reportCallbackDelayMS == 5000 && faults.incomingErrorCode == 0)
  }

  @Test func aFulfilledUnmuteAfterTheCallEndsSettlesPerFramework() throws {
    let policy = try behaviorProfile().fulfilledPostEndUnmutePolicy
    #expect(policy.settlement(for: .callkit) == .timeout)
    #expect(policy.settlement(for: .livecommunicationkit) == .complete)
  }

  @Test func actionTimingFollowsTheFramework() throws {
    let profile = try behaviorProfile()
    let callKitAnswer = profile.timing(api: .callkit, answer: true, start: false)
    #expect(callKitAnswer.deadline == 60 && callKitAnswer.expiry == 59.58)
    let callKitHold = profile.timing(api: .callkit, answer: false, start: false, pauseOrEnd: true)
    #expect(callKitHold.deadline == 5 && callKitHold.expiry == 5.2)
    let callKitStart = profile.timing(api: .callkit, answer: false, start: true)
    #expect(callKitStart.deadline == 600 && callKitStart.expiry == 600)
    let join = profile.timing(api: .livecommunicationkit, answer: true, start: false)
    #expect(join.deadline == 30 && join.expiry == 64)
    let pause = profile.timing(
      api: .livecommunicationkit, answer: false, start: false, pauseOrEnd: true)
    #expect(pause.deadline == 30 && pause.expiry == 5.3)
    let mute = profile.timing(api: .livecommunicationkit, answer: false, start: false)
    #expect(mute.deadline == 30 && mute.expiry == 30)
  }

  // This issue time once rounded a Pause's expiry to 5,299 ms.
  @Test(arguments: [(5.3, Int64(1_792_940_005_308)), (64, 1_792_940_064_008), (5.2, 1_792_940_005_208)])
  func actionExpiriesAreAnchoredToTheJournalsIssueTime(expiry: Double, expiryMS: Int64) {
    let times = ActionJournalTimes(
      issuedAt: Date(timeIntervalSince1970: 1_792_940_000.008), deadlineSeconds: 30,
      expirySeconds: expiry)
    #expect(times.issuedAtMS == 1_792_940_000_008)
    #expect(times.deadlineMS == 1_792_940_030_008)
    #expect(times.expiryMS == expiryMS)
  }
}

/// The LiveCommunicationKit multi-call policy measured on an iPhone 13 with iOS 27.0.
struct LCKMultiCallPolicyTests {
  private static func id(_ suffix: String) -> UUID {
    UUID(uuidString: "00000000-0000-4000-8000-0000000000" + suffix)!
  }
  private let pause = id("01")
  private let join = id("02")
  private let end = id("03")
  private let accepted = id("12")

  /// Settles each action in turn and returns what the barrier released after each one.
  private func settle(
    _ actions: [UUID], _ settlements: [(UUID, Bool)]
  ) -> [[UUID]?] {
    var barrier = LCKMultiCallPolicy.Barrier(actions: actions, joining: [join: accepted])
    return settlements.map { barrier.settle($0.0, fulfilled: $0.1) }
  }

  @Test func aJoinWaitsForEveryOtherAction() {
    let released = settle([pause, join], [(join, true), (pause, true), (pause, true)])
    #expect(released == [nil, [accepted], nil], "The barrier releases once")
  }

  @Test func aFailedPauseStillLetsTheJoin() {
    #expect(settle([pause, join], [(join, true), (pause, false)]) == [nil, [accepted]])
  }

  @Test func aFailedJoinNeverJoins() {
    #expect(settle([pause, join], [(join, false), (pause, true)]) == [nil, []])
  }

  @Test func aFailedEndStillLetsTheJoin() {
    #expect(settle([end, join], [(end, false), (join, true)]) == [nil, [accepted]])
  }

  @Test func audioMovesOnlyAfterBothTheGapAndTheJoin() {
    var delayedEnd = LCKMultiCallPolicy.Handoff()
    let gapFirst = [delayedEnd.markGapElapsed(), delayedEnd.markJoined()]
    #expect(gapFirst == [false, true], "A pending source can't take the audio back")
    var early = LCKMultiCallPolicy.Handoff()
    let joinFirst = [early.markJoined(), early.markGapElapsed()]
    #expect(joinFirst == [false, true], "An early Join can't skip the gap")
  }

  @Test func failuresEndTheirCall() {
    #expect(LCKMultiCallPolicy.failure(.pause) == .endWithCleanup)
    #expect(LCKMultiCallPolicy.failure(.join) == .endWithCleanup)
    #expect(LCKMultiCallPolicy.failure(.end) == .endRegardless)
    #expect(LCKMultiCallPolicy.failure(.merge) == .none)
  }

  @Test func theSystemOffersTheMeasuredChoices() {
    #expect(
      LCKMultiCallPolicy.choices(established: 0, held: 0, active: 0, maximumGroups: 1) == [
        "answer", "decline",
      ])
    #expect(
      LCKMultiCallPolicy.choices(established: 1, held: 0, active: 1, maximumGroups: 1) == [
        "end-and-accept", "decline",
      ])
    #expect(
      LCKMultiCallPolicy.choices(established: 1, held: 0, active: 1, maximumGroups: 2) == [
        "hold-and-accept", "end-and-accept", "decline",
      ])
    #expect(
      LCKMultiCallPolicy.choices(established: 2, held: 1, active: 1, maximumGroups: 2) == [
        "end-and-accept", "decline", "end-held-and-accept",
      ])
  }

  @Test func anOutgoingCallNeedsAFreeGroup() {
    #expect(!LCKMultiCallPolicy.canStart(established: 1, reservedStarts: 0, maximumGroups: 1))
    #expect(!LCKMultiCallPolicy.canStart(established: 1, reservedStarts: 1, maximumGroups: 2))
    #expect(LCKMultiCallPolicy.canStart(established: 1, reservedStarts: 0, maximumGroups: 2))
  }

  @Test func resumingEndsTheActiveCallOnlyWithTwoSingleCallGroups() {
    #expect(LCKMultiCallPolicy.shouldEndActiveOnResume(maximumGroups: 2, maximumPerGroup: 1))
    #expect(!LCKMultiCallPolicy.shouldEndActiveOnResume(maximumGroups: 2, maximumPerGroup: 2))
    #expect(!LCKMultiCallPolicy.shouldEndActiveOnResume(maximumGroups: 1, maximumPerGroup: 1))
    #expect(LCKMultiCallPolicy.resumeEndDelay(nominal: 0.091, elapsedSinceIssued: 0) == 0.091)
    #expect(
      abs(LCKMultiCallPolicy.resumeEndDelay(nominal: 0.091, elapsedSinceIssued: 0.05) - 0.041)
        < 0.000001)
    #expect(
      LCKMultiCallPolicy.resumeEndDelay(nominal: 0.091, elapsedSinceIssued: 2) == 0,
      "A late fulfillment doesn't add another delay")
  }

  @Test func onlySystemCompositesWithAJoinUseTheBarrier() {
    #expect(LCKMultiCallPolicy.usesCompositeBarrier(system: true, actionCount: 2, joiningCount: 1))
    #expect(
      !LCKMultiCallPolicy.usesCompositeBarrier(system: true, actionCount: 1, joiningCount: 1),
      "A single Join keeps its own audio scheduling")
    #expect(
      !LCKMultiCallPolicy.usesCompositeBarrier(system: false, actionCount: 2, joiningCount: 1),
      "Composites from the app weren't measured")
    #expect(
      !LCKMultiCallPolicy.usesCompositeBarrier(system: true, actionCount: 2, joiningCount: 0),
      "Start, mute, tones and grouping don't wait")
  }
}
