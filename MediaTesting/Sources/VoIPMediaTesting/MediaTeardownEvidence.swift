public import Foundation
import Synchronization

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
    /// Identity of the observing clock, unique for this recorder's lifetime.
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
  private let clockID = UUID()
  private let now: @Sendable () -> Double
  /// All timestamps use this clock's origin and remain in milliseconds, including injected clocks.
  public init<C: Clock<Duration>>(clock: C) {
    let origin = clock.now
    now = { Double(origin.duration(to: clock.now) / .milliseconds(1)) }
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
        clockID: clockID, startedAtMs: start, observedAtMs: now(), observations: $0.observations)
    }
  }
}
