import Foundation
import Synchronization

@testable import VoIPFocus

/// What a calling app's Focus filter asks for: who may ring this device.
struct CallSettings: Codable, Hashable, Sendable {
  enum Ringing: String, Codable, Hashable, Sendable {
    case everyone
    case favorites
    case nobody
  }

  /// Outside a Focus, everyone may ring.
  var ringing: Ringing = .everyone
}

/// Settings that can't be encoded as JSON, which has no NaN.
struct UnencodableSettings: Codable, Hashable, Sendable {
  var volume: Double
}

/// Settings whose JSON doesn't decode back.
struct OneWaySettings: Codable, Hashable, Sendable {
  var isDefault = false

  init(isDefault: Bool = false) {
    self.isDefault = isDefault
  }

  init(from decoder: any Decoder) throws {
    throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Never decodes"))
  }
}

/// A wall clock that stands still until the test moves it.
final class TestDates: Sendable {
  /// 31 October 2025, 22:00 UTC: whole seconds, which JSON keeps exactly.
  static let start = Date(timeIntervalSince1970: 1_761_948_000)

  private let current = Mutex(TestDates.start)

  var now: Date {
    current.withLock { $0 }
  }

  func advance(bySeconds seconds: TimeInterval) {
    current.withLock { $0 += seconds }
  }
}

/// Storage in memory that tells its subscribers of each write at once, as the App Group's
/// `UserDefaults` and Darwin notification would, and that the test can change as another process
/// would.
final class FakeStorage: StateStorage {
  private struct State {
    var data: Data?
    var writes = 0
    var subscribers = 0
  }

  private let state = Mutex(State())
  private let signal = LocalSignal()

  /// How many times the store wrote.
  var writes: Int {
    state.withLock { $0.writes }
  }

  /// How many subscriptions are open.
  var subscribers: Int {
    state.withLock { $0.subscribers }
  }

  func read() -> Data? {
    state.withLock { $0.data }
  }

  func write(_ data: Data) throws(FocusFilterStoreError) {
    state.withLock {
      $0.data = data
      $0.writes += 1
    }
    signal.post()
  }

  func subscribe(_ onChange: @escaping @Sendable () -> Void) -> Cancellation {
    state.withLock { $0.subscribers += 1 }
    let cancel = signal.subscribe(onChange)
    return { [weak self] in
      cancel()
      self?.state.withLock { $0.subscribers -= 1 }
    }
  }

  /// Replaces the stored JSON and signals the change, as a Focus filter running in an extension
  /// does.
  func writeFromAnotherProcess(_ json: String) {
    state.withLock { $0.data = Data(json.utf8) }
    signal.post()
  }

  /// Signals a change without changing anything, as a repeated Darwin notification does.
  func signalWithoutChange() {
    signal.post()
  }
}

/// A `UserDefaults` suite that only the test uses, removed when the test's work ends.
func withScratchDefaults<Result>(
  _ body: (UserDefaults, String) async throws -> Result
) async rethrows -> Result {
  let name = "VoIPFocusTests.\(UUID().uuidString)"
  guard let defaults = UserDefaults(suiteName: name) else {
    preconditionFailure("A scratch suite name is always valid")
  }
  defer { defaults.removePersistentDomain(forName: name) }
  return try await body(defaults, name)
}
