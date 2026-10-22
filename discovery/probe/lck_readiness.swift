import Foundation

/// LCK's public delegate witness is nonisolated in older Swift SDK interfaces.
/// Preserve its isolation while sharing observed callbacks with the main waiter.
final class LCKProbeConversationStates: @unchecked Sendable {
  private let lock = NSLock()
  private var states: [UUID: String] = [:]

  func record(_ id: UUID, state: String) { lock.withLock { states[id] = state } }
  subscript(_ id: UUID) -> String? { lock.withLock { states[id] } }
}

/// Simulator-probe liveness policy, independent of native action deadlines.
@MainActor
enum LCKProbeReadiness {
  nonisolated static let livenessLimit: Duration = .seconds(10)

  static func wait(limit: Duration = livenessLimit, until isReady: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: limit)
    while !Task.isCancelled {
      guard clock.now < deadline else { return false }
      let ready = isReady()
      // A synchronous native getter can block main. It cannot be preempted,
      // but a result observed after the liveness budget must not be admitted.
      guard !Task.isCancelled, clock.now < deadline else { return false }
      if ready { return true }
      do { try await Task.sleep(for: .milliseconds(20)) }
      catch { return false }
    }
    return false
  }
}
