public import Foundation
import Synchronization

/// First actual startup observations, retained across probe windows and failed attempts.
public final class MediaStartupEvidence: Sendable {
  /// The independently observed PCM attachment point.
  public enum Tap: String, Codable, Sendable { case decoded, output }
  /// The engine state actually read after an activation attempt.
  public enum Availability: String, Codable, Sendable { case running, unavailable }
  /// Actual result returned by the activation command stream, never inferred consumption.
  public enum Enqueue: String, Codable, Sendable { case enqueued, dropped, terminated }
  /// SDK events observed independently of the media activation command.
  public enum AudioEvent: String, Codable, Sendable { case activated, deactivated }
  /// A measured boundary; a connection failure contains only its error type name.
  public enum Event: Codable, Equatable, Sendable {
    case prepareEntered, roomConnectRequested, roomConnectCompleted
    case roomConnectFailed(errorType: String)
    case captureOptionsApplied
    case prepareCompleted, activationEntered
    case activationEnqueued(Enqueue)
    case activationHandlerEntered
    case engineAvailabilityObserved(Availability)
    case tapInstalled(Tap)
    case firstCallback(Tap)
  }
  /// One first occurrence on the shared observation clock.
  public struct Observation: Codable, Sendable {
    /// The actual boundary and any measured stage-specific value.
    public let event: Event
    /// Milliseconds since the shared clock origin.
    public let atMs: Double
  }
  /// Immutable startup evidence, including missing stages and partial failures.
  public struct Receipt: Codable, Sendable {
    /// Identity shared with PCM, phase and release receipts.
    public let clockID: UUID
    /// First occurrences in recording order; absent stages remain absent.
    public let observations: [Observation]
    /// Latest observed SDK activation event on this clock; nil means no event was observed.
    public let lastAudioActivatedAtMs: Double?
    /// Latest observed SDK deactivation event on this clock; nil never implies inactivity.
    public let lastAudioDeactivatedAtMs: Double?
  }
  private enum Key: Hashable {
    case prepare, connectRequested, connectOutcome, captureOptions, engine
    case prepareCompleted, activationEntered, activationEnqueued, activationHandlerEntered
    case tap(Tap)
    case callback(Tap)
  }
  private struct State {
    var seen: Set<Key> = []
    var observations: [Observation] = []
    var lastAudioActivatedAtMs: Double?
    var lastAudioDeactivatedAtMs: Double?
  }
  private let state = Mutex(State())
  private let clock: MediaObservationClock
  /// Uses the same origin and identity as native PCM, phase and teardown evidence.
  public init(observationClock: MediaObservationClock) { clock = observationClock }
  /// Retains the first occurrence only, at most thirteen rows including both taps.
  /// A connection outcome never replaces an earlier success or failure.
  public func record(_ event: Event) {
    let key: Key
    switch event {
    case .prepareEntered: key = .prepare
    case .roomConnectRequested: key = .connectRequested
    case .roomConnectCompleted, .roomConnectFailed: key = .connectOutcome
    case .captureOptionsApplied: key = .captureOptions
    case .prepareCompleted: key = .prepareCompleted
    case .activationEntered: key = .activationEntered
    case .activationEnqueued: key = .activationEnqueued
    case .activationHandlerEntered: key = .activationHandlerEntered
    case .engineAvailabilityObserved: key = .engine
    case .tapInstalled(let tap): key = .tap(tap)
    case .firstCallback(let tap): key = .callback(tap)
    }
    state.withLock {
      guard $0.seen.insert(key).inserted else { return }
      $0.observations.append(Observation(event: event, atMs: clock.milliseconds))
    }
  }
  /// Records the last actual SDK event of each kind without growing the startup timeline.
  public func recordAudioEvent(_ event: AudioEvent) {
    state.withLock {
      switch event {
      case .activated: $0.lastAudioActivatedAtMs = clock.milliseconds
      case .deactivated: $0.lastAudioDeactivatedAtMs = clock.milliseconds
      }
    }
  }
  /// Returns only recorded stages; taking a failure receipt never fills missing stages.
  public func receipt() -> Receipt {
    state.withLock {
      Receipt(
        clockID: clock.id, observations: $0.observations,
        lastAudioActivatedAtMs: $0.lastAudioActivatedAtMs,
        lastAudioDeactivatedAtMs: $0.lastAudioDeactivatedAtMs)
    }
  }
}
