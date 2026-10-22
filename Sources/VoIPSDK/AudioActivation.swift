import Foundation

/// Proposed defaults until answer-to-activation timing is measured on the reference device.
public struct AudioActivationPolicy: Sendable, Equatable {
  public enum Error: Swift.Error, Sendable { case invalidTimeout }
  public let activationTimeout: TimeInterval
  public let recoveryTimeout: TimeInterval
  public static let standard = AudioActivationPolicy(activation: 10, recovery: 5)

  public init(activationTimeout: TimeInterval = 10, recoveryTimeout: TimeInterval = 5) throws {
    guard activationTimeout.isFinite, activationTimeout > 0,
          recoveryTimeout.isFinite, recoveryTimeout > 0 else { throw Error.invalidTimeout }
    self.init(activation: activationTimeout, recovery: recoveryTimeout)
  }
  private init(activation: TimeInterval, recovery: TimeInterval) {
    activationTimeout = activation; recoveryTimeout = recovery
  }
}

enum AudioActivationEvent: Equatable { case activated, deactivated, missing, failed }

/// One process-wide absence episode, independent of backend work or conversation count.
/// Only the genuine system delegate callbacks may call didActivate/didDeactivate.
@MainActor
final class AudioActivationCoordinator {
  typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> @MainActor () -> Void
  private enum Phase { case waiting, recovering, failed }
  private let policy: AudioActivationPolicy
  private let now: @MainActor () -> TimeInterval
  private let schedule: Schedule
  private var demand: Set<UUID> = []
  private var failedDemand: Set<UUID> = []
  private var generation: UUID?
  private var phase: Phase?
  private var cancelTimer: (@MainActor () -> Void)?
  private var recoveryTask: Task<Void, Never>?
  private(set) var isActive = false
  var onEvent: (@MainActor (AudioActivationEvent) -> Void)?
  var recover: (@MainActor () async -> Void)?
  var endConversations: (@MainActor (Set<UUID>) -> Void)?

  init(policy: AudioActivationPolicy = .standard,
       now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
       schedule: Schedule? = nil) {
    self.policy = policy; self.now = now
    self.schedule = schedule ?? { deadline, fire in
      let task = Task { @MainActor in
        // Chunk long caller-configured intervals to keep Duration conversion finite.
        while !Task.isCancelled {
          let remaining = deadline - ProcessInfo.processInfo.systemUptime
          if remaining <= 0 { fire(); return }
          do { try await Task.sleep(for: .seconds(min(remaining, 3_600))) }
          catch { return }
        }
      }
      return { task.cancel() }
    }
  }

  /// Supply only LCK joined, unheld conversations, never a still-pending app handler.
  func updateDemand(_ ids: Set<UUID>) {
    demand = ids
    if demand.isEmpty { cancelEpisode() }
    else {
      // Coalesced manager updates can replace the last failed call without an
      // intermediate empty snapshot. That new call still needs its own deadline.
      if phase == .failed && failedDemand.isDisjoint(with: demand) { cancelEpisode() }
      if !isActive && generation == nil { beginEpisode() }
    }
  }

  func didActivate() {
    guard !isActive else { return }
    isActive = true; cancelEpisode(); onEvent?(.activated)
  }
  func didDeactivate() {
    guard isActive else { return }
    isActive = false
    onEvent?(.deactivated)
    if !isActive && !demand.isEmpty && generation == nil { beginEpisode() }
  }

  /// Reset invalidates authorization without fabricating a deactivation callback/event.
  func reset() {
    cancelEpisode(); demand.removeAll(); isActive = false
  }

  private func beginEpisode() {
    let id = UUID(); generation = id; phase = .waiting
    cancelTimer = schedule(now() + policy.activationTimeout) { [weak self] in self?.missing(id) }
  }
  private func missing(_ id: UUID) {
    guard generation == id, phase == .waiting, !isActive, !demand.isEmpty else { return }
    phase = .recovering
    cancelTimer?()
    // Arm the final deadline before any observer or async recovery can suspend.
    cancelTimer = schedule(now() + policy.recoveryTimeout) { [weak self] in self?.fail(id) }
    onEvent?(.missing)
    guard generation == id, phase == .recovering, !isActive, !demand.isEmpty else { return }
    recoveryTask = Task { @MainActor [weak self] in
      guard self?.generation == id, self?.isActive == false, self?.demand.isEmpty == false else { return }
      let operation = self?.recover
      // Do not retain this coordinator across an uncooperative recovery operation.
      await operation?()
      if self?.generation == id { self?.recoveryTask = nil }
    }
  }
  private func fail(_ id: UUID) {
    guard generation == id, phase == .recovering, !isActive, !demand.isEmpty else { return }
    phase = .failed; cancelTimer?(); cancelTimer = nil
    recoveryTask?.cancel(); recoveryTask = nil
    let affected = demand
    failedDemand = affected
    onEvent?(.failed)
    // Observers can synchronously end, hold, reset or genuinely activate the session.
    guard generation == id, phase == .failed, !isActive else { return }
    let remaining = affected.intersection(demand)
    if !remaining.isEmpty { endConversations?(remaining) }
  }
  private func cancelEpisode() {
    generation = nil; phase = nil; failedDemand.removeAll()
    cancelTimer?(); cancelTimer = nil
    recoveryTask?.cancel(); recoveryTask = nil
  }
}

/// Orders backend preparation and real callbacks while leaving the watchdog executor free.
/// Awaiting a backend cannot preempt its native work; that limitation never extends the watchdog.
@MainActor
final class AudioAdapterOperations {
  private var tail: Task<Void, Never>?
  private var tailID: UUID?
  var onError: (@MainActor (String) -> Void)?
  func enqueue(_ operation: @escaping @MainActor () async throws -> Void) {
    let previous = tail; let id = UUID(); tailID = id
    tail = Task { @MainActor [weak self] in
      await previous?.value
      do { try await operation() }
      catch { self?.onError?(String(describing: error)) }
      if self?.tailID == id { self?.tail = nil; self?.tailID = nil }
    }
  }
}
