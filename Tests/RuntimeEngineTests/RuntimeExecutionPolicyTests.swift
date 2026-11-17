import CKSimProtocol
import Foundation
import Testing
import VoIPTesting

@testable import CKSimRuntime

struct RuntimeExecutionPolicyTests {
  private typealias Policy = RuntimeExecutionPolicy<TestClock.Instant>
  private struct Fixture {
    let clock: TestClock
    let invocation: ProcessLifecycleIdentity
    var policy: Policy

    init() throws {
      clock = TestClock()
      invocation = try ProcessLifecycleIdentity(
        simulatorID: UUID(), bundleID: "test.calls", runID: "execution-test")
      policy = try Policy(
        scenario: LockedAnswerScenario(
          invocation: invocation, pid: 42, lock: .locked, activity: .background,
          coverage: .explicitAdapters), at: clock.now)
    }

    @discardableResult
    mutating func send(_ event: Policy.Event) throws -> Policy.Decision {
      try policy.reduce(event, invocation: invocation, pid: 42, at: clock.now)
    }
  }

  @Test func lockingDoesNotChangeActivityOrSuspendTheProcess() throws {
    var f = try Fixture()
    #expect(f.policy.decision.eligibility == .suspendEligible)
    #expect(f.policy.decision.execution == .running)
    try f.send(.activity(.foreground))
    for _ in 0..<3 {
      try f.send(.lock(.unlocked))
      let locked = try f.send(.lock(.locked))
      #expect(locked.eligibility == .running)
      #expect(locked.execution == .running && locked.activity == .foreground)
    }
    try f.send(.activity(.background))
    let unlocked = try f.send(.lock(.unlocked))
    #expect(unlocked.eligibility == .suspendEligible)
    #expect(unlocked.lock == .unlocked && unlocked.activity == .background)
  }

  @Test func overlappingAssertionsRetainIndependentIDsDeadlinesAndSources() throws {
    var f = try Fixture()
    let push = UUID()
    let sdk = UUID()
    let app = UUID()
    let origin = f.clock.now
    try f.send(.begin(push, .pushWake, .unverified(.seconds(2))))
    try f.send(.begin(sdk, .sdkPushAssertion, .unverified(.seconds(4))))
    try f.send(.begin(app, .applicationAssertion, .unverified(.seconds(8))))
    #expect(Set(f.policy.decision.assertions.map(\.id)) == [push, sdk, app])
    #expect(f.policy.decision.nextDeadline == origin.advanced(by: .seconds(2)))
    f.clock.advance(by: .seconds(2))
    let afterPush = try f.send(.advance)
    #expect(f.policy.lifetime(of: push) == .expired)
    #expect(afterPush.assertions.count == 2 && afterPush.eligibility == .running)
    #expect(afterPush.nextDeadline == origin.advanced(by: .seconds(4)))
    try f.send(.end(sdk))
    #expect(f.policy.lifetime(of: sdk) == .ended)
    #expect(f.policy.decision.assertions.first?.source == .applicationAssertion)
    #expect(f.policy.decision.assertions.first?.allowance == .unverified(.seconds(8)))
    f.clock.advance(by: .seconds(6))
    let expired = try f.send(.advance)
    #expect(expired.assertions.isEmpty && expired.nextDeadline == nil)
    #expect(expired.eligibility == .suspendEligible)
    #expect(f.policy.lifetime(of: app) == .expired)
  }

  @Test(arguments: [true, false])
  func releaseOrderAndRepeatedEndsCannotReleaseAnotherAssertion(appFirst: Bool) throws {
    var f = try Fixture()
    let app = UUID()
    let sdk = UUID()
    try f.send(.begin(app, .applicationAssertion, .unverified(.seconds(7))))
    try f.send(.begin(sdk, .sdkPushAssertion, .unverified(.seconds(7))))
    let first = appFirst ? app : sdk
    let second = appFirst ? sdk : app
    try f.send(.end(first))
    let repeated = try f.send(.end(first))
    #expect(repeated.eligibility == .running && repeated.assertions.map(\.id) == [second])
    let released = try f.send(.end(second))
    #expect(released.eligibility == .suspendEligible)
  }

  @Test func denialNeverProvidesTimeAndAnExpiredIdentifierCannotBeReused() throws {
    var f = try Fixture()
    let denied = UUID()
    let expired = UUID()
    let denial = try f.send(.begin(denied, .applicationAssertion, .denied))
    #expect(denial.eligibility == .suspendEligible && denial.nextDeadline == nil)
    #expect(f.policy.lifetime(of: denied) == .denied)
    try f.send(.end(denied))
    #expect(f.policy.lifetime(of: denied) == .denied)
    try f.send(.begin(expired, .applicationAssertion, .unverified(.seconds(1))))
    f.clock.advance(by: .seconds(1))
    try f.send(.end(expired))
    #expect(f.policy.lifetime(of: expired) == .expired)
    #expect(throws: Policy.Failure.reusedID) {
      try f.send(.begin(expired, .applicationAssertion, .unverified(.seconds(20))))
    }
    #expect(f.policy.decision.eligibility == .suspendEligible)
  }

  @Test func adapterExpirationIsIndependentOfTheModeledDueTime() throws {
    var f = try Fixture()
    let app = UUID()
    let sdk = UUID()
    try f.send(.begin(app, .applicationAssertion, .unverified(.seconds(20))))
    try f.send(.begin(sdk, .sdkPushAssertion, .unverified(.seconds(10))))
    let expired = try f.send(.expire(app))
    #expect(f.policy.lifetime(of: app) == .expired)
    #expect(expired.eligibility == .running && expired.assertions.map(\.id) == [sdk])
    try f.send(.end(app))
    #expect(f.policy.lifetime(of: app) == .expired)
    try f.send(.end(sdk))
    try f.send(.expire(sdk))
    #expect(f.policy.lifetime(of: sdk) == .ended)
    #expect(f.policy.decision.eligibility == .suspendEligible)
  }

  @Test(arguments: [0, 1, 2, 3, 4, 5, 6, 7])
  func audioRequiresActivationActualMediaAndCapability(bits: Int) throws {
    var f = try Fixture()
    let decision = try f.send(
      .audio(
        UUID(), activated: bits & 1 != 0, mediaActive: bits & 2 != 0,
        backgroundCapable: bits & 4 != 0))
    #expect(decision.eligibility == (bits == 7 ? .running : .suspendEligible))
  }

  @Test func assertionHandsOffToObservedAudioWithoutAnExecutionGap() throws {
    var f = try Fixture()
    let app = UUID()
    let audio = UUID()
    try f.send(.begin(app, .applicationAssertion, .unverified(.seconds(20))))
    try f.send(.audio(audio, activated: true, mediaActive: false, backgroundCapable: true))
    try f.send(.audio(audio, activated: true, mediaActive: true, backgroundCapable: true))
    let handoff = try f.send(.end(app))
    #expect(handoff.eligibility == .running && handoff.assertions.isEmpty)
    #expect(handoff.audio?.id == audio && handoff.nextDeadline == nil)
    let stopped = try f.send(
      .audio(
        audio, activated: false, mediaActive: true, backgroundCapable: true))
    #expect(stopped.eligibility == .suspendEligible)
  }

  @Test func unknownAssertionsRefuseConformanceEvenWithOtherExecutionReasons() throws {
    var f = try Fixture()
    try f.send(.begin(UUID(), .sdkPushAssertion, .unverified(.seconds(2))))
    let unknown = try f.send(.coverage(.unknownAssertions))
    #expect(unknown.eligibility == .unknownCoverage && unknown.assertions.count == 1)
    f.clock.advance(by: .seconds(2))
    try f.send(.advance)
    #expect(f.policy.decision.eligibility == .unknownCoverage)
    let covered = try f.send(.coverage(.explicitAdapters))
    #expect(covered.eligibility == .suspendEligible)
  }

  @Test func eligibilityDoesNotPretendToResumeOrExecuteAnInProcessDeadline() throws {
    var f = try Fixture()
    let app = UUID()
    try f.send(.begin(app, .applicationAssertion, .unverified(.seconds(2))))
    try f.send(.execution(.suspended))
    f.clock.advance(by: .seconds(30))
    // Without another reduction there has been no observation, timeout callback or host wake.
    #expect(f.policy.lifetime(of: app) == .active)
    let elapsed = try f.send(.advance)
    #expect(elapsed.execution == .suspended && elapsed.eligibility == .suspendEligible)
    try f.send(.activity(.foreground))
    #expect(f.policy.decision.execution == .suspended)
    let resumed = try f.send(.execution(.running))
    #expect(resumed.eligibility == .running && resumed.execution == .running)
    #expect(f.policy.lifetime(of: app) == .expired)
  }

  @Test func staleSimulatorBundleRunOrPIDCannotReleaseCurrentAssertions() throws {
    var f = try Fixture()
    let app = UUID()
    try f.send(.begin(app, .applicationAssertion, .unverified(.seconds(1))))
    f.clock.advance(by: .seconds(2))
    let identities = [
      try ProcessLifecycleIdentity(
        simulatorID: UUID(), bundleID: f.invocation.bundleID, runID: f.invocation.runID),
      try ProcessLifecycleIdentity(
        simulatorID: f.invocation.simulatorID, bundleID: "another.app", runID: f.invocation.runID),
      try ProcessLifecycleIdentity(
        simulatorID: f.invocation.simulatorID, bundleID: f.invocation.bundleID, runID: "next-run"),
    ]
    for identity in identities {
      #expect(throws: Policy.Failure.staleIdentity) {
        try f.policy.reduce(.end(app), invocation: identity, pid: 42, at: f.clock.now)
      }
      #expect(f.policy.lifetime(of: app) == .active)
    }
    #expect(throws: Policy.Failure.staleIdentity) {
      try f.policy.reduce(.end(app), invocation: f.invocation, pid: 43, at: f.clock.now)
    }
    #expect(f.policy.lifetime(of: app) == .active)
    try f.send(.advance)
    #expect(f.policy.lifetime(of: app) == .expired)
  }

  @Test func invalidInputsLeaveStateAndObservationTimeUnchanged() throws {
    var f = try Fixture()
    let before = f.policy.decision
    for duration in [Duration.zero, .seconds(-1)] {
      #expect(throws: Policy.Failure.invalidDuration) {
        try f.send(.begin(UUID(), .applicationAssertion, .unverified(duration)))
      }
    }
    #expect(throws: Policy.Failure.unknownID) { try f.send(.end(UUID())) }
    #expect(throws: Policy.Failure.backwardsTime) {
      try f.policy.reduce(
        .activity(.foreground), invocation: f.invocation, pid: 42,
        at: f.clock.now.advanced(by: .nanoseconds(-1)))
    }
    #expect(f.policy.decision == before)
  }

  @Test func exitClearsExecutionReasonsAndCannotBeResurrected() throws {
    var f = try Fixture()
    let app = UUID()
    try f.send(.begin(app, .applicationAssertion, .unverified(.seconds(20))))
    try f.send(.audio(UUID(), activated: true, mediaActive: true, backgroundCapable: true))
    let exited = try f.send(.execution(.exited))
    #expect(exited.eligibility == .exited && exited.execution == .exited)
    #expect(exited.assertions.isEmpty && exited.audio == nil && exited.nextDeadline == nil)
    #expect(f.policy.lifetime(of: app) == .ended)
    #expect(throws: Policy.Failure.processExited) { try f.send(.execution(.running)) }
  }
}
