#if os(iOS)
  import UIKit
  #if DEBUG && targetEnvironment(simulator) && SWIFT_PACKAGE
    @_spi(Simulator) import VoIPCore
  #endif

  /// UIKit permits beginning and ending background tasks from the push registry's queue.
  @available(iOSApplicationExtension, unavailable)
  struct UIKitPushBackgroundExecution: PushBackgroundExecution {
    private let application: UIApplication

    @MainActor init() {
      application = .shared
    }

    func begin(expiration: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
      #if DEBUG && targetEnvironment(simulator)
        return SimulatorBackgroundExecution.begin(
          source: .sdkPushAssertion,
          begin: { expiration in
            let id = application.beginBackgroundTask(
              withName: "VoIP push", expirationHandler: expiration)
            return id == .invalid ? nil : id
          }, end: { application.endBackgroundTask($0) }, expiration: expiration)
      #else
        let identifier = application.beginBackgroundTask(withName: "VoIP push") { expiration() }
        guard identifier != .invalid else { return {} }
        return { application.endBackgroundTask(identifier) }
      #endif
    }
  }
#endif
