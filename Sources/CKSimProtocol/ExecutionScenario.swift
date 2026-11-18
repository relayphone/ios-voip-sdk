public import Foundation

/// Explicit simulator fixture inputs, never measured iOS execution allowances.
public struct ExecutionScenarioConfiguration: Codable, Equatable, Sendable {
  /// Independent lock axis; locking does not itself suspend execution.
  public enum Lock: String, Codable, Sendable { case locked, unlocked }
  /// Explicit fixture activity, independent of lock and process execution.
  public enum Activity: String, Codable, Sendable { case foreground, background }
  /// Coverage asserted by the fixture, never inferred from a returned UIKit identifier.
  public enum Coverage: String, Codable, Sendable { case explicitAdapters, unknownAssertions }
  /// Correlates decisions for one configured scenario in this invocation.
  public let id: UUID
  /// Test input for device lock.
  public let lock: Lock
  /// Test input for application activity.
  public let activity: Activity
  /// Whether the fixture accounts for every assertion it uses.
  public let coverage: Coverage
  /// Unverified upper bound for each fixture application assertion.
  public let applicationAllowanceMS: Int
  /// Unverified upper bound for each SDK push assertion.
  public let sdkPushAllowanceMS: Int
  /// Unsupported fixture durations or fields.
  public enum Failure: Error { case invalidAllowance, unexpectedField }

  /// Requires explicit bounded inputs; no scheduling constants are supplied by the profile.
  public init(
    id: UUID, lock: Lock, activity: Activity, coverage: Coverage,
    applicationAllowanceMS: Int, sdkPushAllowanceMS: Int
  ) throws(Failure) {
    guard (1...120_000).contains(applicationAllowanceMS),
      (1...120_000).contains(sdkPushAllowanceMS)
    else { throw .invalidAllowance }
    self.id = id
    self.lock = lock
    self.activity = activity
    self.coverage = coverage
    self.applicationAllowanceMS = applicationAllowanceMS
    self.sdkPushAllowanceMS = sdkPushAllowanceMS
  }
  private enum CodingKeys: String, CodingKey, CaseIterable {
    case id, lock, activity, coverage, applicationAllowanceMS, sdkPushAllowanceMS
  }
  private struct Field: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }
  /// Validates configuration received over the control mailbox.
  public init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: Field.self).allKeys.map(\.stringValue)
    guard Set(fields).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
      throw Failure.unexpectedField
    }
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: c.decode(UUID.self, forKey: .id), lock: c.decode(Lock.self, forKey: .lock),
      activity: c.decode(Activity.self, forKey: .activity),
      coverage: c.decode(Coverage.self, forKey: .coverage),
      applicationAllowanceMS: c.decode(Int.self, forKey: .applicationAllowanceMS),
      sdkPushAllowanceMS: c.decode(Int.self, forKey: .sdkPushAllowanceMS))
  }
}

/// One explicit policy assessment, not an observed OS scheduling decision.
public struct ExecutionDecisionSnapshot: Codable, Equatable, Sendable {
  /// Assessment failure retained for diagnostics; no eligibility claim survives it.
  public enum Failure: String, Codable, Sendable { case assessmentFailed }
  /// Verification available for fixture policy allowances.
  public enum Verification: String, Codable, Sendable { case unverified }
  /// Actual execution is independent of policy eligibility.
  public enum Execution: String, Codable, Sendable { case running, suspended, exited }
  /// Policy result; unknown coverage never permits a suspension conformance claim.
  public enum Eligibility: String, Codable, Sendable {
    case running, suspendEligible, unknownCoverage, exited
  }
  /// One bounded active modeled reason, with fixture provenance.
  public struct Reason: Codable, Equatable, Sendable {
    /// Independent assertion attempt.
    public let id: UUID
    /// Explicit adapter that emitted the observation.
    public let source: BackgroundAssertionSnapshot.Source
    /// Original fixture bound, never remaining background time reported by UIKit.
    public let unverifiedAllowanceMS: Int
    /// Absolute monotonic due time derived from the actual begin return.
    public let dueUptimeNanoseconds: UInt64
    /// Retains an active reason for wire and journal projection.
    public init(
      id: UUID, source: BackgroundAssertionSnapshot.Source,
      unverifiedAllowanceMS: Int, dueUptimeNanoseconds: UInt64
    ) {
      self.id = id
      self.source = source
      self.unverifiedAllowanceMS = unverifiedAllowanceMS
      self.dueUptimeNanoseconds = dueUptimeNanoseconds
    }
  }
  /// Configuration retained with each decision for provenance.
  public let configuration: ExecutionScenarioConfiguration
  /// Time when this policy read the current assertion history.
  public let assessedAt: UInt64
  /// Independent axes and assertion evidence determine this result.
  public let eligibility: Eligibility
  /// Absent on a successful assessment, including a valid unknown-coverage result.
  public let failure: Failure?
  /// An in-process acknowledgement observes running execution; it never confirms host suspension.
  public let execution: Execution
  /// These allowances are fixture inputs, not measured iOS durations.
  public let verification: Verification
  /// Active bounded reasons; an empty list does not imply known coverage.
  public let reasons: [Reason]
  /// Earliest active modeled due time, absent when no bounded reason remains.
  public let nextDeadline: UInt64?
  /// Constructs an assessment for status and the existing runtime journal.
  public init(
    configuration: ExecutionScenarioConfiguration, assessedAt: UInt64,
    eligibility: Eligibility, reasons: [Reason], failure: Failure? = nil
  ) {
    self.configuration = configuration
    self.assessedAt = assessedAt
    self.eligibility = eligibility
    self.failure = failure
    self.execution = .running
    self.verification = .unverified
    self.reasons = reasons
    self.nextDeadline = reasons.map(\.dueUptimeNanoseconds).min()
  }
}
