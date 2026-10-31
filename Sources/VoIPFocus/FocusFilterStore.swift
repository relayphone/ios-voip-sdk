public import Foundation
import Synchronization

/// The Focus filter state, shared by the app and its extensions through an App Group.
///
/// The system runs the app's Focus filter in whichever process declares it, often an App Intents
/// extension while the app isn't running. The filter records each run in the store, and the app
/// reads the state or follows its changes from the same App Group:
///
/// ```swift
/// struct CallSettings: Codable, Hashable, Sendable {
///   var ringing: Ringing = .everyone
/// }
///
/// let store = FocusFilterStore<CallSettings>(appGroup: "group.com.example.calls")
///
/// // Where the filter runs, with the settings its Focus asks for:
/// let state = try store.record(CallSettings(ringing: .favorites), defaults: CallSettings())
///
/// // In the app:
/// for await state in store.states() {
///   await server.updateFocusFilterState(state)
/// }
/// ```
///
/// The store keeps the state's JSON in the App Group's `UserDefaults`, and posts a Darwin
/// notification after each change, so every process that follows ``states()`` reads it again.
/// When two processes record at once, the last write wins. Settings that no longer decode, for
/// example after the app changed its settings type, read as ``FocusFilterState/unknown``.
///
/// Give the app and every extension that records or reads the state the same App Group. Without
/// it, the state reads as unknown and ``record(_:defaults:)`` throws
/// ``FocusFilterStoreError/appGroupUnavailable``.
public final class FocusFilterStore<Settings: Codable & Hashable & Sendable>: Sendable {
  private let storage: any StateStorage
  /// The time at which the store records a state.
  private let now: @Sendable () -> Date

  /// Creates a store in an App Group's shared container.
  ///
  /// Creating a store is cheap, and every store for the same App Group shares one state. Keep one
  /// in a static property where the filter can reach it, and use it from the app too.
  ///
  /// - Parameter appGroup: The App Group identifier, such as `group.com.example.calls`, which the
  ///   app and its extensions all have.
  public convenience init(appGroup: String) {
    self.init(
      storage: DefaultsStorage(appGroup: appGroup) ?? UnavailableStorage(), now: { Date() })
  }

  /// Creates a store in a `UserDefaults` that only this process uses, such as for tests and
  /// previews.
  ///
  /// The store follows only its own changes: ``states()`` doesn't see another store's
  /// ``record(_:defaults:)``, even in the same `UserDefaults`. Use ``init(appGroup:)`` to share
  /// the state with the app's extensions.
  ///
  /// - Parameter userDefaults: Where the store keeps the state.
  public convenience init(userDefaults: UserDefaults) {
    self.init(
      storage: DefaultsStorage(defaults: userDefaults, signal: LocalSignal()), now: { Date() })
  }

  init(storage: any StateStorage, now: @escaping @Sendable () -> Date) {
    self.storage = storage
    self.now = now
  }

  /// The Focus filter state that was last recorded, by any process that shares the store.
  ///
  /// Reading it is synchronous and fast. Send it to the app's servers, and let them choose how
  /// each call appears on this device: every VoIP push must be reported as a call, so a call that
  /// should only be a call preview needs another kind of push (see ADR 0006).
  public var state: FocusFilterState<Settings> {
    Self.state(in: storage)
  }

  /// Returns a stream of the Focus filter state: the current state, then each change that any
  /// process records.
  ///
  /// The stream ends when the task that reads it is cancelled.
  public func states() -> AsyncStream<FocusFilterState<Settings>> {
    let (stream, continuation) = AsyncStream.makeStream(of: FocusFilterState<Settings>.self)
    let follower = Follower(continuation: continuation)
    let storage = storage
    // Subscribe before reading the current state, so that no change falls in between.
    let cancel = storage.subscribe { follower.yield { Self.state(in: storage) } }
    continuation.onTermination = { _ in cancel() }
    follower.yield { Self.state(in: storage) }
    return stream
  }

  /// Records what the Focus filter asks for when it runs with these settings: inactive when they
  /// equal the filter's defaults, and active otherwise.
  ///
  /// A Focus filter's `perform()` calls it, with the settings its parameters ask for and the
  /// settings of a filter whose parameters all have their defaults. When the filter already asked
  /// for the same, the store keeps the earlier state, with its date, and nothing changes.
  ///
  /// - Parameters:
  ///   - settings: The settings that the filter's parameters ask for.
  ///   - defaults: The settings of the filter when every parameter has its default value.
  /// - Returns: The state that the store holds now.
  /// - Throws: ``FocusFilterStoreError/appGroupUnavailable`` when this process doesn't belong to
  ///   the store's App Group, or ``FocusFilterStoreError/encodingFailed`` when the settings can't
  ///   be encoded as JSON, or don't decode from the JSON they encode to.
  @discardableResult
  public func record(_ settings: Settings, defaults: Settings) throws(FocusFilterStoreError)
    -> FocusFilterState<Settings>
  {
    let next = FocusFilterState(settings, defaults: defaults, since: now())
    let current = state
    if current.asksForTheSame(as: next) { return current }
    let data: Data
    let recorded: FocusFilterState<Settings>
    do {
      data = try JSONEncoder().encode(next)
      // The state as every reader decodes it, with its date as precise as its JSON number.
      recorded = try JSONDecoder().decode(FocusFilterState<Settings>.self, from: data)
    } catch {
      throw .encodingFailed
    }
    try storage.write(data)
    return recorded
  }

  /// The state that the storage holds, or unknown when it holds none or can't be decoded.
  private static func state(in storage: any StateStorage) -> FocusFilterState<Settings> {
    guard let data = storage.read(),
      let state = try? JSONDecoder().decode(FocusFilterState<Settings>.self, from: data)
    else { return .unknown }
    return state
  }
}

/// Why the store couldn't record the Focus filter state.
public enum FocusFilterStoreError: Error, Hashable, Sendable {
  /// This process doesn't belong to the store's App Group. Add the App Group to the target's
  /// capabilities.
  case appGroupUnavailable
  /// The settings couldn't be encoded as JSON, or didn't decode from the JSON they encoded to.
  case encodingFailed
}

/// One stream from ``FocusFilterStore/states()``. It yields the state whenever it differs from
/// the last state it yielded.
private final class Follower<Settings: Codable & Hashable & Sendable>: Sendable {
  private let last = Mutex<FocusFilterState<Settings>?>(nil)
  private let continuation: AsyncStream<FocusFilterState<Settings>>.Continuation

  init(continuation: AsyncStream<FocusFilterState<Settings>>.Continuation) {
    self.continuation = continuation
  }

  /// Reads the state, and yields it when it changed. Reading and yielding under one lock keeps
  /// the stream in the order of the reads.
  func yield(_ read: () -> FocusFilterState<Settings>) {
    last.withLock { last in
      let state = read()
      guard state != last else { return }
      last = state
      continuation.yield(state)
    }
  }
}
