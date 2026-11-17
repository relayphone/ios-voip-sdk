#if DEBUG && os(iOS) && targetEnvironment(simulator)
  import UIKit
  #if SWIFT_PACKAGE
    @_spi(Simulator) import VoIPCore
  #endif

  /// A real UIKit assertion adapter for an explicitly configured simulator fixture.
  ///
  /// Publishes Debug SPI observations to the embedded runtime. This adapter does not model
  /// an iOS allowance, prove a system grant, or expire an unknown system assertion.
  @available(iOSApplicationExtension, unavailable)
  public struct UIKitBackgroundExecution: Sendable {
    private let application: UIApplication

    /// Uses the fixture application's real UIKit background-task API.
    @MainActor public init() { application = .shared }

    /// Requests background time and returns the owner's end operation.
    /// The owner ends a valid request exactly once, including after expiration.
    public func begin(expiration: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
      SimulatorBackgroundExecution.begin(
        source: .applicationAssertion,
        begin: { expiration in
          let id = application.beginBackgroundTask(
            withName: "VoIP fixture", expirationHandler: expiration)
          return id == .invalid ? nil : id
        }, end: { application.endBackgroundTask($0) }, expiration: expiration)
    }
  }
#endif
