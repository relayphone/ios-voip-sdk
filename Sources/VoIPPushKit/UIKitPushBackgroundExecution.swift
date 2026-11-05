#if os(iOS)
  import UIKit

  /// UIKit permits beginning and ending background tasks from the push registry's queue.
  @available(iOSApplicationExtension, unavailable)
  struct UIKitPushBackgroundExecution: PushBackgroundExecution {
    private let application: UIApplication

    @MainActor init() {
      application = .shared
    }

    func begin(expiration: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
      let identifier = application.beginBackgroundTask(withName: "VoIP push") { expiration() }
      guard identifier != .invalid else { return {} }
      return { application.endBackgroundTask(identifier) }
    }
  }
#endif
