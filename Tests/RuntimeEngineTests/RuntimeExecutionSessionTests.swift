import CKSimProtocol
import Foundation
import Testing
import VoIPTesting

@testable import CKSimRuntime

struct RuntimeExecutionSessionTests {
  private typealias Session = RuntimeExecutionSession<TestClock.Instant>
  private func config(coverage: ExecutionScenarioConfiguration.Coverage = .explicitAdapters) throws
    -> ExecutionScenarioConfiguration
  {
    try .init(
      id: UUID(), lock: .locked, activity: .background, coverage: coverage,
      applicationAllowanceMS: 5000, sdkPushAllowanceMS: 2000)
  }
  private func session(_ configuration: ExecutionScenarioConfiguration) throws -> Session {
    try Session(
      configuration: configuration,
      invocation: ProcessLifecycleIdentity(
        simulatorID: UUID(), bundleID: "example.calls", runID: "session"),
      pid: 42, epoch: 100, at: TestClock().now)
  }
  @Test func projectionPreservesConfigurationProvenanceAndAbsoluteDueTime() throws {
    let configuration = try config()
    var session = try session(configuration)
    var row = BackgroundAssertionSnapshot(
      id: UUID(), source: .applicationAssertion, requestedAt: 100)
    row.beganAt = 200
    let history = BackgroundAssertionsSnapshot(hasUnresolvedObservations: false, assertions: [row])
    let decision = session.read(history, uptime: 2_000_000_200)
    #expect(decision.configuration == configuration && decision.assessedAt == 2_000_000_200)
    #expect(decision.eligibility == .running)
    #expect(decision.reasons.first?.id == row.id)
    #expect(decision.reasons.first?.unverifiedAllowanceMS == 5000)
    #expect(decision.nextDeadline == 5_000_000_200)
    #expect(session.read(history, uptime: 5_000_000_200).eligibility == .suspendEligible)
    #expect(
      try JSONDecoder().decode(
        ExecutionDecisionSnapshot.self,
        from: JSONEncoder().encode(decision)) == decision)
  }
  @Test(arguments: [false, true])
  func failedAssessmentKeepsStatusReadableAndCannotBeHidden(regressedTime: Bool) throws {
    var session = try session(config())
    var row = BackgroundAssertionSnapshot(id: UUID(), source: .sdkPushAssertion, requestedAt: 100)
    row.beganAt = 100
    let history = BackgroundAssertionsSnapshot(hasUnresolvedObservations: false, assertions: [row])
    #expect(session.read(history, uptime: 100).eligibility == .running)
    let failure = session.read(
      regressedTime ? history : .init(hasUnresolvedObservations: false, assertions: []),
      uptime: regressedTime ? 99 : 101)
    for decision in [failure, session.read(history, uptime: 102)] {
      #expect(decision.eligibility == .unknownCoverage)
      #expect(decision.failure == .assessmentFailed)
      #expect(decision.reasons.isEmpty && decision.nextDeadline == nil)
      var status = try JSONDecoder().decode(
        RuntimeSnapshot.self,
        from: Data(
          #"{"calls":[],"pending":0,"audioActive":false,"sequence":1,"incomingErrorCode":0,"incomingFilter":{"reason":"none","code":0,"verification":"not-applicable"},"providerConfigurations":[]}"#
            .utf8))
      status.executionDecision = decision
      let result = ControlResult.status(status)
      #expect(
        try JSONDecoder().decode(ControlResult.self, from: JSONEncoder().encode(result)) == result)
    }
  }
  @Test func missingAndUnknownCoverageNeverBecomeSuspendEligible() throws {
    for unknown in [false, true] {
      var session = try session(config(coverage: unknown ? .unknownAssertions : .explicitAdapters))
      let decision = session.read(
        unknown ? .init(hasUnresolvedObservations: false, assertions: []) : nil,
        uptime: 100)
      #expect(decision.eligibility == .unknownCoverage && decision.reasons.isEmpty)
      #expect(decision.failure == nil)
    }
  }
}
