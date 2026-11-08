#if VOIP_CONVERSATIONS_FOCUS
  import Foundation
  import os

  #if os(iOS)
    import UIKit
  #endif

  /// The Focus filter state, with the `focusFilter` plugin option: what the app's Focus filter
  /// last asked for, which the filter records in the App Group wherever the system runs it.
  ///
  /// The module doesn't know the app's settings type, so it reads the settings as JSON. JavaScript
  /// receives the state exactly as ios-voip-sdk encodes it for the app's servers, as a revisioned
  /// snapshot.
  @MainActor
  final class FocusFilter {
    private static let log = Logger(subsystem: "VoIPFocus", category: "bridge")
    private let store: FocusFilterStore<JSONValue>
    private let changed: @MainActor (JSONValue) -> Void
    private var revision = 0
    private var state: JSONValue
    private var task: Task<Void, Never>?
    private var foregroundTask: Task<Void, Never>?

    /// Creates the Focus filter state of an App Group.
    ///
    /// - Parameters:
    ///   - appGroup: The App Group in which the app's Focus filter records its state.
    ///   - changed: Sends a new snapshot to JavaScript.
    init(appGroup: String, changed: @escaping @MainActor (JSONValue) -> Void) {
      store = FocusFilterStore(appGroup: appGroup)
      self.changed = changed
      state = Self.json(store.state)
      Self.log.notice(
        "Store read reason=launch state=\(Self.stateName(self.state), privacy: .public)")
    }

    isolated deinit {
      task?.cancel()
      foregroundTask?.cancel()
    }

    /// The TypeScript API's `FocusFilterStateSnapshot`.
    var snapshot: JSONValue {
      Self.log.notice(
        "JS snapshot state=\(Self.stateName(self.state), privacy: .public) revision=\(self.revision)"
      )
      return .object(["revision": .number(Double(revision)), "state": state])
    }

    /// Follows the state's changes, which any process that shares the App Group records.
    func start() {
      guard task == nil else { return }
      let states = store.states()
      task = Task { [weak self] in
        for await state in states { self?.update(state) }
      }
      #if os(iOS)
        let foregrounds = NotificationCenter.default.notifications(
          named: UIApplication.didBecomeActiveNotification
        ).map { _ in () }
        foregroundTask = Task { [weak self] in
          for await _ in foregrounds { self?.logForegroundRead() }
        }
      #endif
    }

    private func update(_ state: FocusFilterState<JSONValue>) {
      let json = Self.json(state)
      Self.log.notice("Store read reason=change state=\(Self.stateName(json), privacy: .public)")
      guard json != self.state else { return }
      self.state = json
      revision += 1
      changed(snapshot)
    }

    /// Compares persistence with the snapshot without changing what JavaScript receives.
    private func logForegroundRead() {
      let current = Self.json(store.state)
      Self.log.notice(
        "Store read reason=foreground state=\(Self.stateName(current), privacy: .public); JS state=\(Self.stateName(self.state), privacy: .public) revision=\(self.revision)"
      )
    }

    /// Logs only the state tag, never settings or timestamps.
    private static func stateName(_ state: JSONValue) -> String {
      guard case .object(let object) = state else { return "unknown" }
      switch object["state"] {
      case .string("active"): return "active"
      case .string("inactive"): return "inactive"
      default: return "unknown"
      }
    }

    /// The state's JSON object, as the SDK encodes it for the app's servers.
    private static func json(_ state: FocusFilterState<JSONValue>) -> JSONValue {
      guard let data = try? JSONEncoder().encode(state),
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
      else {
        Self.log.error("Focus state conversion failed; returning unknown")
        return .object(["state": .string("unknown")])
      }
      return json
    }
  }
#endif
