import Foundation
import VoIPPlatform

public enum AudioEngineAvailability: Sendable, Equatable { case none, `default` }

// Test-owned, lock-protected backend state; no framework type is asserted Sendable.
public final class AudioSession: @unchecked Sendable {
  private let lock = NSLock()
  private var automatic = true
  public var isAutomaticConfigurationEnabled: Bool {
    get { lock.withLock { automatic } }
    set {
      precondition(VSAudioSessionIsOnQueue() && !Thread.isMainThread)
      lock.withLock { automatic = newValue }
    }
  }
}
public final class AudioManager: @unchecked Sendable {
  public static let shared = AudioManager()
  public let audioSession = AudioSession()
  private let condition = NSCondition()
  private var blocked = false
  private var started = false
  private var values: [AudioEngineAvailability] = []
  public func armSuspendedPreparation() {
    condition.lock(); defer { condition.unlock() }
    blocked = true; started = false; values.removeAll()
  }
  public var preparationStarted: Bool {
    condition.lock(); defer { condition.unlock() }; return started
  }
  public var calls: [AudioEngineAvailability] {
    condition.lock(); defer { condition.unlock() }; return values
  }
  public func clear() {
    condition.lock(); defer { condition.unlock() }; values.removeAll()
  }
  public func releasePreparation() {
    condition.lock(); blocked = false; condition.broadcast(); condition.unlock()
  }
  public func setEngineAvailability(_ value: AudioEngineAvailability) throws {
    precondition(VSAudioSessionIsOnQueue() && !Thread.isMainThread)
    condition.lock(); defer { condition.unlock() }
    if blocked {
      started = true
      let deadline = Date().addingTimeInterval(3)
      while blocked {
        guard condition.wait(until: deadline) else { throw Failure.timedOut }
      }
    }
    values.append(value)
  }
  private enum Failure: Error { case timedOut }
}
