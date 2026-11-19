public import Foundation

/// Native service ownership for a system Answer. Install the authority before push intake so it
/// can run on a cold launch. Each result belongs to the supplied Answer receipt.
public protocol AnswerAuthority: Sendable {
  /// Claims the call within the request's remaining time.
  ///
  /// If cancellation races with a grant, return the grant so the SDK can release it. Release it
  /// in the authority if cancellation prevents returning it.
  func claim(_ request: AnswerRequest) async -> AnswerDecision

  /// Checks the original claim once, without creating another claim. Return nil if unknown.
  func reconcile(_ request: AnswerRequest) async -> AnswerDecision?

  /// Relinquishes an unused or ended grant. Cleanup is independent of system action settlement.
  func release(_ permit: AnswerPermit, for request: AnswerRequest) async
}

/// One operation on the original system Answer receipt.
public struct AnswerRequest: Sendable {
  /// Call identity and native metadata, as captured when Answer arrived.
  public let call: Call
  /// The original action ID, shared by claim, reconciliation, and release.
  public let actionID: ActionID
  /// Time left for this operation, measured on the SDK's monotonic clock.
  public var remaining: Duration { max(.zero, deadline - now()) }

  let deadline: Duration
  let now: @Sendable () -> Duration
}

/// A service grant for an Answer.
public struct AnswerPermit: Hashable, Sendable {
  /// Opaque service identifier for this permit.
  public let id: String
  /// The service's expiry, if supplied.
  public let expiresAt: Date?

  /// Creates a grant with its service identifier and optional expiry.
  public init(id: String, expiresAt: Date? = nil) {
    self.id = id
    self.expiresAt = expiresAt
  }
}

/// A typed result from the native authority.
public enum AnswerDecision: Hashable, Sendable {
  /// This receipt owns the Answer.
  case allow(AnswerPermit)
  /// The service decided that this receipt may not answer.
  case refuse(AnswerRefusal)
  /// The authority could not obtain a decision.
  case unavailable(AnswerAuthorityFailure)
}

/// Why the service refused an Answer.
public enum AnswerRefusal: String, Hashable, Sendable {
  /// Another device or service already answered.
  case answeredElsewhere
  /// Another device or service already declined.
  case declinedElsewhere
  /// The service does not permit this receipt to answer.
  case notAllowed
}

/// Why the native authority could not obtain a decision.
public enum AnswerAuthorityFailure: Hashable, Sendable {
  /// Native credentials could not be used.
  case credentialsUnavailable
  /// The service could not be reached.
  case network
  /// The authority returned no valid response.
  case invalidResponse
}

/// Why the SDK rejected a native Answer during authorization.
public enum AnswerFailure: Hashable, Sendable {
  /// The authority refused the Answer for a known reason.
  case refused(AnswerRefusal)
  /// The claim expired and one reconciliation produced no decision.
  case claimTimedOut
  /// The authority was unavailable before the claim deadline.
  case unavailable(AnswerAuthorityFailure)
  /// The system's action deadline left insufficient time for the configured stages.
  case invalidBudget
}

/// Monotonic limits for native Answer, including preparation and system settlement.
public struct AnswerBudget: Hashable, Sendable {
  /// Time from the original system Answer receipt.
  public let total: Duration
  /// Time for the first claim.
  public let claim: Duration
  /// Time for the one reconciliation after claim expiry.
  public let reconciliation: Duration
  /// Time kept for system settlement after media preparation.
  public let settlementReserve: Duration

  /// The maximum supported allocation, in milliseconds.
  public static let standard = AnswerBudget(
    total: .milliseconds(4500), claim: .milliseconds(2500),
    reconciliation: .milliseconds(500), settlementReserve: .milliseconds(500))

  /// Creates an allocation. Client startup validates its limits and the framework's deadline.
  public init(
    total: Duration, claim: Duration, reconciliation: Duration, settlementReserve: Duration
  ) {
    self.total = total
    self.claim = claim
    self.reconciliation = reconciliation
    self.settlementReserve = settlementReserve
  }

  func isValid(effectiveDeadline: Duration) -> Bool {
    let limits = Self.standard
    return [
      (total, min(limits.total, effectiveDeadline)), (claim, limits.claim),
      (reconciliation, limits.reconciliation), (settlementReserve, limits.settlementReserve),
    ].allSatisfy { value, limit in
      value > .zero && value <= limit
        && value.components.attoseconds.isMultiple(of: 1_000_000_000_000_000)
    } && fits(total)
  }

  func fits(_ duration: Duration) -> Bool {
    claim + reconciliation + settlementReserve < duration
  }
}
