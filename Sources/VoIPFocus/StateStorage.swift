import Dispatch
import Foundation
import Synchronization
import notify

/// Where a store keeps the encoded state, and how it hears that the state changed. App Group
/// `UserDefaults` is behind it in apps, and tests use a fake.
protocol StateStorage: Sendable {
  /// The encoded state, or `nil` when none was recorded.
  func read() -> Data?

  /// Replaces the encoded state, then tells every subscriber, in every process that shares the
  /// storage.
  func write(_ data: Data) throws(FocusFilterStoreError)

  /// Calls `onChange` after each write until the returned cancellation runs.
  ///
  /// `onChange` may run on any thread, and more than once for one write.
  func subscribe(_ onChange: @escaping @Sendable () -> Void) -> Cancellation
}

/// Stops a subscription when it runs.
typealias Cancellation = @Sendable () -> Void

/// Tells subscribers that the state changed: within one process, or across processes.
protocol ChangeSignal: Sendable {
  /// Tells every subscriber.
  func post()

  /// Calls `onChange` after each post until the returned cancellation runs.
  func subscribe(_ onChange: @escaping @Sendable () -> Void) -> Cancellation
}

/// The state in `UserDefaults`, under one key, with a signal for its changes.
struct DefaultsStorage: StateStorage {
  /// The key under which the store keeps the state's JSON.
  static let key = "VoIPFocus.FocusFilterState"

  // `UserDefaults` is thread-safe, as its documentation says.
  nonisolated(unsafe) private let defaults: UserDefaults
  private let signal: any ChangeSignal

  init(defaults: UserDefaults, signal: any ChangeSignal) {
    self.defaults = defaults
    self.signal = signal
  }

  /// The App Group's shared `UserDefaults`, with a Darwin notification named after the App Group,
  /// or `nil` when this process doesn't belong to the App Group.
  init?(appGroup: String) {
    guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil,
      let defaults = UserDefaults(suiteName: appGroup)
    else { return nil }
    self.init(defaults: defaults, signal: DarwinSignal(name: "\(appGroup).\(Self.key)"))
  }

  func read() -> Data? {
    defaults.data(forKey: Self.key)
  }

  func write(_ data: Data) throws(FocusFilterStoreError) {
    defaults.set(data, forKey: Self.key)
    signal.post()
  }

  func subscribe(_ onChange: @escaping @Sendable () -> Void) -> Cancellation {
    signal.subscribe(onChange)
  }
}

/// The storage of a store whose App Group this process doesn't belong to: it holds nothing and
/// refuses every write.
struct UnavailableStorage: StateStorage {
  func read() -> Data? {
    nil
  }

  func write(_ data: Data) throws(FocusFilterStoreError) {
    throw .appGroupUnavailable
  }

  func subscribe(_ onChange: @escaping @Sendable () -> Void) -> Cancellation {
    {}
  }
}

/// A Darwin notification, which the system delivers to every process that observes its name,
/// including the one that posts it.
struct DarwinSignal: ChangeSignal {
  let name: String

  func post() {
    notify_post(name)
  }

  func subscribe(_ onChange: @escaping @Sendable () -> Void) -> Cancellation {
    var token: Int32 = 0
    let queue = DispatchQueue(label: "VoIPFocus.DarwinSignal")
    let status = notify_register_dispatch(name, &token, queue) { @Sendable _ in onChange() }
    guard status == NOTIFY_STATUS_OK else { return {} }
    return { [token] in _ = notify_cancel(token) }
  }
}

/// A signal within this process.
final class LocalSignal: ChangeSignal {
  private struct Subscribers {
    var onChange: [Int: @Sendable () -> Void] = [:]
    var nextKey = 0
  }

  private let subscribers = Mutex(Subscribers())

  init() {}

  func post() {
    let onChange = subscribers.withLock { Array($0.onChange.values) }
    for call in onChange { call() }
  }

  func subscribe(_ onChange: @escaping @Sendable () -> Void) -> Cancellation {
    let key = subscribers.withLock { subscribers in
      defer { subscribers.nextKey += 1 }
      subscribers.onChange[subscribers.nextKey] = onChange
      return subscribers.nextKey
    }
    return { [weak self] in
      _ = self?.subscribers.withLock { $0.onChange.removeValue(forKey: key) }
    }
  }
}
