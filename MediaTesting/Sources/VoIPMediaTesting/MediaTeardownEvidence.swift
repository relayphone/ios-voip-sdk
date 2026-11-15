public import Foundation
import Synchronization

/// A single monotonic origin shared by native phase, PCM and release observations.
public final class MediaObservationClock: Sendable {
  /// Identity acknowledged by the adapter for the lifetime of this clock.
  public let id = UUID()
  private let read: @Sendable () -> Double
  /// Uses the injected clock without changing its units or origin between observers.
  public init<C: Clock<Duration>>(clock: C) {
    let origin = clock.now
    read = {
      let elapsed = origin.duration(to: clock.now).components
      return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
  }
  /// Creates a system monotonic clock with a fresh identity.
  public convenience init() { self.init(clock: ContinuousClock()) }
  /// Seconds since the shared origin.
  public var seconds: Double { read() }
  /// Milliseconds since the same origin.
  public var milliseconds: Double { read() * 1000 }
}

/// Measured release observations for one actual call; missing observations never imply silence.
public final class MediaTeardownEvidence: Sendable {
  /// Independent observations made by the actual room, graph and system audio callbacks.
  public enum Event: String, Codable, CaseIterable, Sendable {
    case tapUninstalled, engineStopped, roomDisconnected, audioSessionReleased
  }
  /// One observation on the recorder's monotonic clock.
  public struct Observation: Codable, Sendable {
    /// What the adapter observed.
    public let event: Event
    /// Milliseconds from this clock's origin.
    public let atMs: Double
  }
  /// An incomplete or complete release attempt; consumers must bind it to their call and deadline.
  public struct Receipt: Codable, Sendable {
    /// Identity of the observing clock, shared with the adapter's phase observers.
    public let clockID: UUID
    /// Time teardown was armed.
    public let startedAtMs: Double
    /// Time this snapshot was taken.
    public let observedAtMs: Double
    /// First occurrence of each measured event, in observation order.
    public let observations: [Observation]
    /// Whether all four release observations were received in this attempt.
    public var complete: Bool { Set(observations.map(\.event)) == Set(Event.allCases) }
  }
  private struct State {
    var startedAtMs: Double?
    var observations: [Observation] = []
  }
  private let state = Mutex(State())
  private let observationClock: MediaObservationClock
  private let now: @Sendable () -> Double
  /// All timestamps use this clock's origin and remain in milliseconds, including injected clocks.
  public convenience init<C: Clock<Duration>>(clock: C) {
    self.init(observationClock: MediaObservationClock(clock: clock))
  }
  /// Shares the phase adapter's clock identity and origin.
  public init(observationClock: MediaObservationClock) {
    self.observationClock = observationClock
    now = { observationClock.milliseconds }
  }
  /// Creates a recorder using the system monotonic clock.
  public convenience init() { self.init(clock: ContinuousClock()) }
  /// Arms a new teardown, retiring all evidence from an earlier call or attempt.
  public func begin() {
    state.withLock { $0 = State(startedAtMs: now()) }
  }
  /// Records only an observation actually made by the adapter after teardown was armed.
  /// Duplicate callbacks retain the first observation on the same clock.
  public func record(_ event: Event) {
    state.withLock {
      guard $0.startedAtMs != nil, !$0.observations.contains(where: { $0.event == event }) else {
        return
      }
      $0.observations.append(Observation(event: event, atMs: now()))
    }
  }
  /// Returns independent evidence, including incomplete attempts. Never manufactures missing events.
  public func receipt() -> Receipt? {
    state.withLock {
      guard let start = $0.startedAtMs else { return nil }
      return Receipt(
        clockID: observationClock.id, startedAtMs: start, observedAtMs: now(),
        observations: $0.observations)
    }
  }
}
