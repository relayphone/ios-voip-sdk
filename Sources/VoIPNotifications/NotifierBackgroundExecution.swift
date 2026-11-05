#if os(iOS)
  import UIKit
#endif

/// Begins background execution for a notification operation and returns its end operation.
@MainActor
protocol NotifierBackgroundExecution {
  func begin() -> @MainActor () -> Void
}

#if os(iOS)
  /// App extensions build notification content but don't run the app's notifier.
  @available(iOSApplicationExtension, unavailable)
  struct UIKitNotifierBackgroundExecution: NotifierBackgroundExecution {
    func begin() -> @MainActor () -> Void {
      let task = NotificationBackgroundTask()
      return { task.end() }
    }
  }

  @available(iOSApplicationExtension, unavailable)
  @MainActor
  private final class NotificationBackgroundTask {
    private let application = UIApplication.shared
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init() {
      identifier = application.beginBackgroundTask(withName: "Call notification") { [weak self] in
        self?.end()
      }
    }

    func end() {
      guard identifier != .invalid else { return }
      let identifier = self.identifier
      self.identifier = .invalid
      application.endBackgroundTask(identifier)
    }
  }
#endif
