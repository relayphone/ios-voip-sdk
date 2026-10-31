#if DEBUG && os(iOS) && targetEnvironment(simulator) && SWIFT_PACKAGE
  import CKSimRuntime
#endif

/// Calls in the iOS Simulator, which has no call service of its own.
///
/// The simulator runtime stands in for the system's call service beneath CallKit,
/// LiveCommunicationKit and PushKit, so that the SDK's adapters run unchanged: calls
/// are reported, ring, are answered and activate audio as on a device, and the runtime can
/// deliver VoIP pushes. It follows measurements from a device, but it uses private simulator
/// interfaces, so it only runs in Debug builds for the simulator.
///
/// Activate it when the app launches, before `VoIPClient.start`:
///
/// ```swift
/// VoIPSimulator.activate()
/// let client = try VoIPClient.start(
///   framework: LiveCommunicationKitAdapter(), media: media, push: PushKitSource())
/// ```
public enum VoIPSimulator {
  /// Activates the simulator runtime in this process.
  ///
  /// Activate it before the calling framework adapter starts. Activating it again does nothing.
  /// In a Release build, or on a device, it does nothing and returns `false`. When the runtime
  /// can't activate, it logs why, leaves the system frameworks as they are and returns `false`.
  ///
  /// - Returns: Whether the runtime is active.
  @MainActor
  @discardableResult
  public static func activate() -> Bool {
    #if DEBUG && os(iOS) && targetEnvironment(simulator)
      RuntimeBootstrap.activate()
    #else
      false
    #endif
  }
}
