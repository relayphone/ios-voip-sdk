#if os(iOS) && targetEnvironment(simulator) && SWIFT_PACKAGE
import CKSimRuntime
#endif

/// Activates the SDK's simulator service before creating a ConversationManager.
@MainActor
public enum SimulatorSupport {
  public enum ConfigurationError: Error { case activationAlreadyRequested }
  private static var enabled = true
  private static var activationRequested = false

  /// Configure during launch, before any manager or explicit activation request.
  public static func configure(enabled: Bool) throws {
    guard !activationRequested || self.enabled == enabled else {
      throw ConfigurationError.activationAlreadyRequested
    }
    self.enabled = enabled
  }

  /// Returns false on devices or when activation is refused. Repeated activation
  /// reuses the process runtime. A refusal logs its reason and leaves genuine APIs.
  @discardableResult
  public static func activateIfNeeded() -> Bool {
    activationRequested = true
    guard enabled else { return false }
    #if os(iOS) && targetEnvironment(simulator)
    return RuntimeBootstrap.activate()
    #else
    return false
    #endif
  }
}
