#if os(iOS) && targetEnvironment(simulator) && SWIFT_PACKAGE
import CKSimRuntime
#endif
#if os(iOS) && targetEnvironment(simulator)
import Foundation

// Kept outside the MainActor type: task-local storage follows async child work,
// rather than the thread on which the PushKit callback happened to execute.
enum SimulatorPushContext {
  @TaskLocal static var pushIdentifier: String?
}
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

  #if os(iOS) && targetEnvironment(simulator)
  static var currentPushIdentifier: String? { RuntimeBootstrap.currentPushIdentifier }

  static func associateIncomingReport(_ id: UUID) {
    guard let pushID = SimulatorPushContext.pushIdentifier else { return }
    RuntimeBootstrap.associateIncomingReport(id, pushID: pushID)
  }
  #endif
}
