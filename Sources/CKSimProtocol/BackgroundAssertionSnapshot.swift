public import Foundation

/// Observed explicit UIKit adapters in one runtime invocation, never exhaustive OS coverage.
public struct BackgroundAssertionsSnapshot: Codable, Equatable, Sendable {
  /// A missing, contradictory or out-of-order boundary prevents using this history as coverage.
  public let hasUnresolvedObservations: Bool
  /// Independent begin attempts in deterministic identifier order, including terminal attempts.
  public let assertions: [BackgroundAssertionSnapshot]

  /// Retains observations without inferring an execution allowance.
  public init(hasUnresolvedObservations: Bool, assertions: [BackgroundAssertionSnapshot]) {
    self.hasUnresolvedObservations = hasUnresolvedObservations
    self.assertions = assertions
  }
}

/// Real adapter boundaries. A returned UIKit identifier does not prove an execution grant.
public struct BackgroundAssertionSnapshot: Codable, Equatable, Sendable {
  /// The explicitly instrumented adapter.
  public enum Source: String, Codable, Sendable {
    /// Fixture-owned UIKit request.
    case applicationAssertion
    /// SDK-owned push-processing UIKit request.
    case sdkPushAssertion
  }
  /// Observed state, independent of modeled expiration deadlines and execution decisions.
  public enum Lifetime: String, Codable, Sendable {
    /// Begin was called but has not returned.
    case requested
    /// Begin returned a valid identifier; this is not proof of an OS grant.
    case returnedIdentifier
    /// Begin returned an invalid identifier.
    case denied
    /// The real expiration callback ran.
    case expired
    /// The owner's end call returned, including cleanup after expiration.
    case ended
  }
  /// Correlates one begin attempt; never a UIKit identifier.
  public let id: UUID
  /// Adapter provenance, not a claim about other system work.
  public let source: Source
  /// Absolute monotonic time before calling UIKit begin.
  public let requestedAt: UInt64
  /// Absolute monotonic time after begin returned a valid identifier.
  public var beganAt: UInt64?
  /// Absolute monotonic time after begin returned an invalid identifier.
  public var deniedAt: UInt64?
  /// Absolute monotonic time at the actual expiration callback, possibly before begin returned.
  public var expiredAt: UInt64?
  /// Absolute monotonic time after the first owner end returned.
  public var endedAt: UInt64?
  /// Every observed end return, so duplicate cleanup remains visible.
  public var endCount: UInt = 0
  /// Terminal observations dominate a later begin return.
  public var lifetime: Lifetime {
    if endedAt != nil { return .ended }
    if expiredAt != nil { return .expired }
    if deniedAt != nil { return .denied }
    return beganAt == nil ? .requested : .returnedIdentifier
  }

  /// Starts an observed attempt. Later boundaries retain their actual callback timestamps.
  public init(id: UUID, source: Source, requestedAt: UInt64) {
    self.id = id
    self.source = source
    self.requestedAt = requestedAt
  }
}
