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
    let decision = try session.read(history, uptime: 2_000_000_200)
    #expect(decision.configuration == configuration && decision.assessedAt == 2_000_000_200)
    #expect(decision.eligibility == .running)
    #expect(decision.reasons.first?.id == row.id)
    #expect(decision.reasons.first?.unverifiedAllowanceMS == 5000)
    #expect(decision.nextDeadline == 5_000_000_200)
    #expect(try session.read(history, uptime: 5_000_000_200).eligibility == .suspendEligible)
    #expect(
      try JSONDecoder().decode(
        ExecutionDecisionSnapshot.self,
        from: JSONEncoder().encode(decision)) == decision)
  }
  @Test func failedHistoryReadCannotBeHiddenByLaterCleanHistory() throws {
    var session = try session(config())
    var row = BackgroundAssertionSnapshot(id: UUID(), source: .sdkPushAssertion, requestedAt: 100)
    row.beganAt = 100
    let history = BackgroundAssertionsSnapshot(hasUnresolvedObservations: false, assertions: [row])
    #expect(try session.read(history, uptime: 100).eligibility == .running)
    #expect(throws: (any Error).self) {
      try session.read(.init(hasUnresolvedObservations: false, assertions: []), uptime: 101)
    }
    #expect(throws: (any Error).self) { try session.read(history, uptime: 102) }
  }
  @Test func missingAndUnknownCoverageNeverBecomeSuspendEligible() throws {
    for unknown in [false, true] {
      var session = try session(config(coverage: unknown ? .unknownAssertions : .explicitAdapters))
      let decision = try session.read(
        unknown ? .init(hasUnresolvedObservations: false, assertions: []) : nil,
        uptime: 100)
      #expect(decision.eligibility == .unknownCoverage && decision.reasons.isEmpty)
    }
  }
}
