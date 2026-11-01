#if os(iOS)
  import UIKit
#endif

/// Whether the app is active, which the notifier waits for before it requests a join.
///
/// `ApplicationActivity` is the app's own; tests use another. CocoaPods builds every library into
/// one module, so the name differs from the push source's own.
@MainActor
protocol NotifierAppActivity {
  /// Whether the app is active: in the foreground, and receiving events.
  var isActive: Bool { get }

  /// Returns a new stream that yields each time the app becomes active from now on, until it is
  /// cancelled.
  func activations() -> AsyncStream<Void>
}

#if os(iOS)
  /// The app's activity, as UIKit reports it. App extensions can't read the app's state.
  @available(iOSApplicationExtension, unavailable)
  struct ApplicationActivity: NotifierAppActivity {
    var isActive: Bool {
      UIApplication.shared.applicationState == .active
    }

    func activations() -> AsyncStream<Void> {
      let (activations, continuation) = AsyncStream.makeStream(of: Void.self)
      let center = NotificationCenter.default
      let token = center.addObserver(of: UIApplication.self, for: .didBecomeActive) { _ in
        continuation.yield()
      }
      continuation.onTermination = { _ in center.removeObserver(token) }
      return activations
    }
  }
#endif
