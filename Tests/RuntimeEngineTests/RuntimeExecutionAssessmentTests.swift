import CKSimProtocol
import Foundation
import Testing
import VoIPTesting

@testable import CKSimRuntime

#if DEBUG
  @_spi(Simulator) import VoIPCore
#endif

struct RuntimeExecutionAssessmentTests {
  private typealias Assessment = RuntimeExecutionAssessment<TestClock.Instant>
  private struct Fixture {
    let clock = TestClock()
    let invocation: ProcessLifecycleIdentity
    var assessment: Assessment
    var rows: [BackgroundAssertionSnapshot] = []
    var state = Assessment.State(lock: .locked, activity: .background, execution: .running)
    var uptime: UInt64 = 100
    init() throws {
      invocation = try ProcessLifecycleIdentity(
        simulatorID: UUID(), bundleID: "example.calls", runID: "assessment")
      assessment = try Assessment(
        scenario: LockedAnswerScenario(
          invocation: invocation, pid: 42, lock: .locked,
          activity: .background, coverage: .explicitAdapters),
        allowances: .init(applicationAssertion: .seconds(5), sdkPushAssertion: .seconds(2)),
        epoch: 100, at: clock.now)
    }
    mutating func assess(unresolved: Bool = false, wake: Assessment.Wake? = nil) throws
      -> Assessment.Policy.Decision
    {
      try assessment.assess(
        .init(hasUnresolvedObservations: unresolved, assertions: rows),
        invocation: invocation, pid: 42, state: state, wake: wake, uptime: uptime)
    }
    mutating func advance(_ seconds: Int) {
      clock.advance(by: .seconds(seconds))
      uptime += UInt64(seconds) * 1_000_000_000
    }
    mutating func begin(_ source: BackgroundAssertionSnapshot.Source = .applicationAssertion) {
      var row = BackgroundAssertionSnapshot(id: UUID(), source: source, requestedAt: uptime)
      row.beganAt = uptime
      rows.append(row)
    }
  }

  @Test func pollingDoesNotExtendTheObservedAllowance() throws {
    var f = try Fixture()
    let origin = f.clock.now
    f.begin()
    f.advance(4)
    let first = try f.assess()
    #expect(first.eligibility == .running)
    #expect(first.assertions.first?.allowance == .unverified(.seconds(5)))
    #expect(first.nextDeadline == origin.advanced(by: .seconds(5)))
    f.advance(1)
    let due = try f.assess()
    #expect(due.eligibility == .suspendEligible && due.assertions.isEmpty)
    // This is only model expiration: no callback or UIKit expiration was synthesized.
    #expect(f.rows.first?.expiredAt == nil)
  }

  @Test func overlappingSourcesDenialAndActualExpirationRemainIndependent() throws {
    var f = try Fixture()
    f.begin(.sdkPushAssertion)
    f.begin()
    var denied = BackgroundAssertionSnapshot(
      id: UUID(), source: .applicationAssertion, requestedAt: 100)
    denied.deniedAt = 100
    f.rows.append(denied)
    #expect(try f.assess().assertions.count == 2)
    f.advance(1)
    f.rows[1].expiredAt = f.uptime
    #expect(try f.assess().assertions.map(\.id) == [f.rows[0].id])
    f.advance(1)
    #expect(try f.assess().eligibility == .suspendEligible)
  }

  @Test func pendingBeginRefusesCoverageAndExpirationBeforeReturnCannotReviveIt() throws {
    var f = try Fixture()
    f.rows = [.init(id: UUID(), source: .applicationAssertion, requestedAt: 100)]
    #expect(try f.assess().eligibility == .unknownCoverage)
    f.advance(1)
    f.rows[0].expiredAt = f.uptime
    #expect(try f.assess().eligibility == .unknownCoverage)
    f.advance(1)
    f.rows[0].beganAt = f.uptime
    #expect(try f.assess().eligibility == .suspendEligible)
    f.rows[0].endedAt = f.uptime
    f.rows[0].endCount = 1
    #expect(try f.assess().eligibility == .suspendEligible)
    f.rows[0].endCount = 2
    #expect(try f.assess().assertions.isEmpty)
  }

  @Test func absentAndUnresolvedHistoriesRemainUnknownAfterLaterCleanReads() throws {
    for absent in [false, true] {
      var f = try Fixture()
      let decision =
        try absent
        ? f.assessment.assess(
          nil, invocation: f.invocation, pid: 42, state: f.state, uptime: f.uptime)
        : f.assess(unresolved: true)
      #expect(decision.eligibility == .unknownCoverage)
      f.begin()
      #expect(try f.assess().eligibility == .unknownCoverage)
    }
  }

  @Test func identityTimeAndHistoryFailuresDoNotCommitPartialAssessment() throws {
    var f = try Fixture()
    f.begin()
    let original = try f.assess()
    #expect(throws: Assessment.Failure.staleIdentity) {
      try f.assessment.assess(
        .init(hasUnresolvedObservations: false, assertions: f.rows),
        invocation: f.invocation, pid: 43, state: f.state, uptime: 100)
    }
    f.advance(1)
    let saved = f.rows
    f.rows = []
    #expect(throws: Assessment.Failure.regressedHistory) { try f.assess() }
    f.rows = saved
    #expect(try f.assess().assertions == original.assertions)
    f.uptime = 99
    #expect(throws: Assessment.Failure.invalidTime) { try f.assess() }
  }

  @Test func malformedWireHistoryNeverProducesAConformanceDecision() throws {
    for control in 0..<6 {
      var f = try Fixture()
      f.begin()
      switch control {
      case 0: f.rows[0].beganAt = 99
      case 1: f.rows[0].deniedAt = 100
      case 2: f.rows[0].endedAt = 100
      case 3: f.rows[0].beganAt = 101
      case 4: f.rows.append(f.rows[0])
      default:
        f.rows[0].beganAt = nil
        f.rows[0].deniedAt = 100
        f.rows[0].expiredAt = 101
        f.uptime = 102
      }
      #expect(try f.assess().eligibility == .unknownCoverage)
      f.rows = []
      // A duplicate may leave its first valid attempt retained; erasing it is a regression.
      if control != 4 { #expect(try f.assess().eligibility == .unknownCoverage) }
    }
  }

  #if DEBUG
    @Test func actualObservationProjectionFeedsTheExistingPolicy() throws {
      var f = try Fixture()
      var observations = RuntimeBackgroundAssertions()
      let id = UUID()
      for kind in [SimulatorBackgroundExecution.Event.Kind.requested, .began] {
        observations.observe(
          .init(id: id, source: .applicationAssertion, kind: kind, uptimeNanoseconds: 100),
          epoch: 100, now: 100)
      }
      let active = try f.assessment.assess(
        observations.snapshot, invocation: f.invocation,
        pid: 42, state: f.state, uptime: 100)
      #expect(active.assertions.map(\.id) == [id])
      observations.observe(
        .init(id: id, source: .applicationAssertion, kind: .expired, uptimeNanoseconds: 200),
        epoch: 100, now: 200)
      let expired = try f.assessment.assess(
        observations.snapshot, invocation: f.invocation,
        pid: 42, state: f.state, uptime: 200)
      #expect(expired.eligibility == .suspendEligible && expired.assertions.isEmpty)
    }
  #endif

  @Test func wakeAndAudioHandoffUseExplicitEvidenceWithoutResumingTheProcess() throws {
    var f = try Fixture()
    let wake = Assessment.Wake(
      id: UUID(), beganAt: 100, endedAt: nil, unverifiedAllowance: .seconds(3))
    #expect(try f.assess(wake: wake).assertions.first?.source == .pushWake)
    f.advance(3)
    f.state = .init(
      lock: .unlocked, activity: .background, execution: .suspended,
      audio: .init(id: UUID(), activated: true, mediaActive: true, backgroundCapable: true))
    let audio = try f.assess(wake: wake)
    #expect(audio.eligibility == .running && audio.execution == .suspended)
    #expect(audio.assertions.isEmpty)
    f.state = .init(lock: .locked, activity: .background, execution: .exited)
    #expect(try f.assess(wake: wake).eligibility == .exited)
    #expect(throws: Assessment.Failure.processExited) { try f.assess(wake: wake) }
  }

  @Test func changingOrDroppingWakeHistoryIsRejected() throws {
    var f = try Fixture()
    let id = UUID()
    try #require(
      f.assess(
        wake: .init(
          id: id, beganAt: 100, endedAt: 100,
          unverifiedAllowance: .seconds(3))
      ).assertions.isEmpty)
    #expect(throws: Assessment.Failure.regressedHistory) { try f.assess() }
    #expect(throws: Assessment.Failure.regressedHistory) {
      try f.assess(
        wake: .init(id: id, beganAt: 100, endedAt: nil, unverifiedAllowance: .seconds(3)))
    }
  }
}
