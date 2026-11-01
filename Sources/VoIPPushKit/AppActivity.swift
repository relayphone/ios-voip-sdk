#if os(iOS)
  import Foundation
  import Synchronization
  import UIKit

  /// Whether the app is active, in the foreground, as UIKit last told the main thread.
  ///
  /// PushKit calls the push source on `VoIPActor.queue`, where reading
  /// `UIApplication.applicationState` would wait for the main thread. So the source follows the
  /// app's activity from UIKit's notifications, which arrive on the main thread, and reads it on
  /// its own queue. The app counts as inactive until UIKit says that it became active: an app
  /// that a VoIP push launches starts in the background.
  final class AppActivity: Sendable {
    private struct State {
      var isActive = false
      var observations: [NotificationCenter.ObservationToken] = []
    }

    private let center: NotificationCenter
    private let state = Mutex(State())

    /// Starts following the app's activity.
    ///
    /// - Parameter center: The notification center that UIKit posts to.
    init(center: NotificationCenter = .default) {
      self.center = center
      let observations = [
        center.addObserver(of: UIApplication.self, for: .didBecomeActive) { [weak self] _ in
          self?.state.withLock { $0.isActive = true }
        },
        center.addObserver(of: UIApplication.self, for: .willResignActive) { [weak self] _ in
          self?.state.withLock { $0.isActive = false }
        },
      ]
      state.withLock { $0.observations = observations }
    }

    deinit {
      for observation in state.withLock({ $0.observations }) {
        center.removeObserver(observation)
      }
    }

    /// Whether the app is active. It can be read on any thread.
    var isActive: Bool {
      state.withLock { $0.isActive }
    }
  }
#endif
