#if os(iOS) && targetEnvironment(simulator)
  import Foundation
  import Synchronization
  import UIKit

  // UIKit delivers these typed messages synchronously on main. Publish their state for PushKit's
  // arbitrary delivery queue without waiting on main. A cold launch starts with the launch budget.
  final class RuntimeApplicationActivity: Sendable {
    private struct State {
      var activity = PushReportingProfile.ApplicationState.launching
      var stopObserving: (@Sendable () -> Void)?
    }
    private let storage = Mutex(State())

    init(center: NotificationCenter = .default) {
      // Standalone packages still have an iOS 18 deployment target; this measured profile is
      // for iOS 27. Older hosts use the explicitly unverified activity fallback.
      guard #available(iOS 26, *) else {
        storage.withLock { $0.activity = .unknown }
        return
      }
      let observations = [
        center.addObserver(of: UIApplication.self, for: .didEnterBackground) { [weak self] _ in
          self?.storage.withLock { $0.activity = .background }
        },
        center.addObserver(of: UIApplication.self, for: .willEnterForeground) { [weak self] _ in
          self?.storage.withLock { $0.activity = .foreground }
        },
        center.addObserver(of: UIApplication.self, for: .didBecomeActive) { [weak self] _ in
          self?.storage.withLock { $0.activity = .foreground }
        },
      ]
      storage.withLock {
        $0.stopObserving = {
          for observation in observations { center.removeObserver(observation) }
        }
      }
    }

    var state: PushReportingProfile.ApplicationState { storage.withLock { $0.activity } }
    func stop() {
      let stop = storage.withLock {
        let stop = $0.stopObserving
        $0.stopObserving = nil
        return stop
      }
      stop?()
    }
    deinit { stop() }
  }
#endif
