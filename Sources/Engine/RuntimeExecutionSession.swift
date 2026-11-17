#if os(macOS) || (os(iOS) && targetEnvironment(simulator))
  import Foundation
  #if SWIFT_PACKAGE
    import CKSimProtocol
  #endif

  /// One immutable opt-in fixture configuration; runtime startup never creates a session.
  struct RuntimeExecutionSession<Instant: InstantProtocol & Sendable>: Sendable
  where Instant.Duration == Duration {
    private let configuration: ExecutionScenarioConfiguration
    private let invocation: ProcessLifecycleIdentity
    private let pid: Int
    private var assessment: RuntimeExecutionAssessment<Instant>
    private var failed = false
    enum Failure: Error {
      case assessmentFailed
      case assessment(RuntimeExecutionAssessment<Instant>.Failure)
    }

    init(
      configuration: ExecutionScenarioConfiguration, invocation: ProcessLifecycleIdentity,
      pid: Int, epoch: UInt64, at origin: Instant
    ) throws(RuntimeExecutionAssessment<Instant>.Failure) {
      self.configuration = configuration
      self.invocation = invocation
      self.pid = pid
      assessment = try RuntimeExecutionAssessment(
        scenario: LockedAnswerScenario(
          invocation: invocation, pid: pid,
          lock: configuration.lock == .locked ? .locked : .unlocked,
          activity: configuration.activity == .background ? .background : .foreground,
          coverage: configuration.coverage == .explicitAdapters
            ? .explicitAdapters : .unknownAssertions),
        allowances: .init(
          applicationAssertion: .milliseconds(configuration.applicationAllowanceMS),
          sdkPushAssertion: .milliseconds(configuration.sdkPushAllowanceMS)), epoch: epoch,
        at: origin)
    }

    /// Keeps diagnostics readable while permanently refusing eligibility after a failed read.
    mutating func read(_ assertions: BackgroundAssertionsSnapshot?, uptime: UInt64)
      -> ExecutionDecisionSnapshot
    {
      do {
        return try assess(assertions, uptime: uptime)
      } catch {
        failed = true
        return .init(
          configuration: configuration, assessedAt: uptime, eligibility: .unknownCoverage,
          reasons: [], failure: .assessmentFailed)
      }
    }

    /// A failed assessment poisons the session so later clean history cannot conceal a gap.
    private mutating func assess(_ assertions: BackgroundAssertionsSnapshot?, uptime: UInt64)
      throws(Failure)
      -> ExecutionDecisionSnapshot
    {
      guard !failed else { throw Failure.assessmentFailed }
      let decision: RuntimeExecutionAssessment<Instant>.Policy.Decision
      do {
        decision = try assessment.assess(
          assertions, invocation: invocation, pid: pid,
          state: .init(
            lock: configuration.lock == .locked ? .locked : .unlocked,
            activity: configuration.activity == .background ? .background : .foreground,
            execution: .running), uptime: uptime)
      } catch {
        failed = true
        throw .assessment(error)
      }
      do {
        let eligibility: ExecutionDecisionSnapshot.Eligibility
        switch decision.eligibility {
        case .running: eligibility = .running
        case .suspendEligible: eligibility = .suspendEligible
        case .unknownCoverage: eligibility = .unknownCoverage
        case .exited: eligibility = .exited
        }
        let reasons = try decision.assertions.map {
          assertion throws(Failure) -> ExecutionDecisionSnapshot.Reason in
          guard let row = assertions?.assertions.first(where: { $0.id == assertion.id }),
            let began = row.beganAt
          else { throw Failure.assessmentFailed }
          let allowance =
            row.source == .applicationAssertion
            ? configuration.applicationAllowanceMS : configuration.sdkPushAllowanceMS
          let (due, overflow) = began.addingReportingOverflow(UInt64(allowance) * 1_000_000)
          guard !overflow else { throw Failure.assessmentFailed }
          return .init(
            id: row.id, source: row.source, unverifiedAllowanceMS: allowance,
            dueUptimeNanoseconds: due)
        }
        return .init(
          configuration: configuration, assessedAt: uptime, eligibility: eligibility,
          reasons: reasons)
      } catch {
        failed = true
        throw error
      }
    }
  }
#endif
