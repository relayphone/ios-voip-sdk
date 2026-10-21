#if os(iOS) && targetEnvironment(simulator) && SWIFT_PACKAGE
import CKSimRuntime
#endif

/// Activates the SDK's simulator service before creating a ConversationManager.
@MainActor
public enum SimulatorSupport {
  /// Returns false on devices or when activation is refused. Repeated activation
  /// reuses the process runtime. A refusal logs its reason and leaves genuine APIs.
  @discardableResult
  public static func activateIfNeeded() -> Bool {
    #if os(iOS) && targetEnvironment(simulator)
    return RuntimeBootstrap.activate()
    #else
    return false
    #endif
  }
}
