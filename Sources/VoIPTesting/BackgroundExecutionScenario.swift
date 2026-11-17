public import Foundation
import Synchronization

/// An explicit fake assertion adapter for background-execution tests.
///
/// This object never calls UIKit or expires a real system assertion. Advance the injected
/// clock, then call ``expireDueAssertions()`` to deliver modeled expirations deterministically.
public final class BackgroundExecutionScenario: Sendable {
  /// The adapter or wake boundary represented by an assertion.
  public enum Source: Equatable, Sendable {
    /// Explicit scenario input for the end of a PushKit wake.
    case pushWake
    /// The fixture application's assertion.
    case applicationAssertion
    /// The SDK's existing push assertion.
    case sdkPushAssertion
  }

  /// A failure control consumed by the next begin operation.
  public enum BeginBehavior: Sendable {
    /// Return a live fake assertion.
    case allow
    /// Record denial, return no identifier and never invoke expiration.
    case deny
    /// Deliver expiration synchronously before returning the identifier.
    case expireBeforeReturn
  }

  /// Invalid fixture input, rejected before consuming a failure control.
  public enum Failure: Error, Equatable, Sendable {
    /// Every modeled allowance must be positive.
    case invalidAllowance
  }

  /// One typed adapter boundary; time is elapsed from this scenario's clock origin.
  public struct Observation: Equatable, Sendable {
    /// The assertion boundary, including source and unverified allowance at begin.
    public enum Kind: Equatable, Sendable {
      /// A fake assertion became available.
      case began(UUID, Source, unverifiedAllowance: Duration)
      /// The fake adapter denied a begin request.
      case denied(UUID, Source)
      /// The fake adapter delivered its expiration handler.
      case expired(UUID)
      /// The owner ended its fake assertion.
      case ended(UUID)
    }
    /// Registration order, starting at one; disambiguates equal clock instants.
    public let sequence: UInt64
    /// Monotonic elapsed time, independent of wall-clock dates.
    public let elapsed: Duration
    /// The observed adapter operation.
    public let kind: Kind
  }

  /// Retained fake state, including duplicate end attempts for exactly-once checks.
  public struct Assertion: Sendable {
    /// Independent identifier for this begin operation.
    public let id: UUID
    /// The adapter that requested the assertion.
    public let source: Source
    /// Scenario input, never a measured iOS scheduling duration.
    public let unverifiedAllowance: Duration
    /// The modeled expiration relative to the scenario origin.
    public let due: Duration
    /// Whether the fake expiration handler was delivered.
    public fileprivate(set) var expired = false
    /// Whether the owner ended this identifier, including after expiration.
    public fileprivate(set) var ended = false
    /// All end attempts, so duplicate cleanup is visible to tests.
    public fileprivate(set) var endAttempts = 0
  }

  private struct Entry {
    var assertion: Assertion
    var expiration: (@Sendable () -> Void)?
  }
  private struct State {
    var behavior: [BeginBehavior] = []
    var entries: [Entry] = []
    var history: [Observation] = []
  }
  private let state = Mutex(State())
  private let elapsed: @Sendable () -> Duration
  private let output: AsyncStream<Observation>.Continuation
  /// One ordered observation stream; use a single consumer or inspect ``history``.
  public let observations: AsyncStream<Observation>

  /// Creates an independent scenario on a monotonic clock supplied by the test.
  public init<C: Clock>(clock: C) where C.Duration == Duration {
    let origin = clock.now
    elapsed = { origin.duration(to: clock.now) }
    (observations, output) = AsyncStream.makeStream(of: Observation.self)
  }

  deinit { output.finish() }

  /// All boundaries in their registration order.
  public var history: [Observation] { state.withLock { $0.history } }
  /// All allowed assertions in begin order, including expired and ended identifiers.
  public var assertions: [Assertion] { state.withLock { $0.entries.map(\.assertion) } }

  /// Queues a begin outcome. Unconfigured begins are allowed.
  public func enqueue(_ behavior: BeginBehavior) {
    state.withLock { $0.behavior.append(behavior) }
  }

  /// Begins a fake assertion, optionally denying or expiring it before return.
  ///
  /// The expiration callback runs outside synchronization and may reenter this adapter.
  public func begin(
    source: Source, unverifiedAllowance: Duration, expiration: @escaping @Sendable () -> Void
  ) throws(Failure) -> UUID? {
    guard unverifiedAllowance > .zero else { throw .invalidAllowance }
    let id = UUID()
    let behavior = state.withLock { state in
      let behavior = state.behavior.isEmpty ? .allow : state.behavior.removeFirst()
      if case .deny = behavior {
        record(.denied(id, source), in: &state)
      } else {
        let now = elapsed()
        state.entries.append(
          Entry(
            assertion: Assertion(
              id: id, source: source, unverifiedAllowance: unverifiedAllowance,
              due: now + unverifiedAllowance), expiration: expiration))
        record(.began(id, source, unverifiedAllowance: unverifiedAllowance), in: &state)
      }
      return behavior
    }
    switch behavior {
    case .deny: return nil
    case .allow: return id
    case .expireBeforeReturn:
      expire(id)
      return id
    }
  }

  /// Ends only this fake identifier. Returns false for an unknown or already-ended ID.
  /// Expiration does not replace the owner's responsibility to end an allowed assertion.
  @discardableResult
  public func end(_ id: UUID) -> Bool {
    state.withLock { state in
      guard let index = state.entries.firstIndex(where: { $0.assertion.id == id }) else {
        return false
      }
      state.entries[index].assertion.endAttempts += 1
      guard !state.entries[index].assertion.ended else { return false }
      state.entries[index].assertion.ended = true
      state.entries[index].expiration = nil
      record(.ended(id), in: &state)
      return true
    }
  }

  /// Expires only an active assertion owned by this fake, delivering its handler once.
  @discardableResult
  public func expire(_ id: UUID) -> Bool {
    let callback = state.withLock { state -> (@Sendable () -> Void)? in
      guard let index = state.entries.firstIndex(where: { $0.assertion.id == id }),
        !state.entries[index].assertion.ended, !state.entries[index].assertion.expired
      else { return nil }
      state.entries[index].assertion.expired = true
      let callback = state.entries[index].expiration
      state.entries[index].expiration = nil
      record(.expired(id), in: &state)
      return callback
    }
    callback?()
    return callback != nil
  }

  /// Delivers due fake expirations in deadline order, with begin order as the tie breaker.
  /// Advancing the clock alone never invokes an application callback.
  public func expireDueAssertions() {
    let ids = state.withLock { state in
      let now = elapsed()
      return state.entries.enumerated().filter {
        !$0.element.assertion.ended && !$0.element.assertion.expired
          && $0.element.assertion.due <= now
      }.sorted {
        let left = $0.element.assertion.due
        let right = $1.element.assertion.due
        return left == right ? $0.offset < $1.offset : left < right
      }.map { $0.element.assertion.id }
    }
    for id in ids { expire(id) }
  }

  private func record(_ kind: Observation.Kind, in state: inout State) {
    let observation = Observation(
      sequence: UInt64(state.history.count) + 1, elapsed: elapsed(), kind: kind)
    state.history.append(observation)
    output.yield(observation)
  }
}
