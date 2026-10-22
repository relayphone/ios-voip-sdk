import Foundation

/// Expo launch adapter selection. Native Swift apps use the dependency-free
/// core's explicit MediaAdapter registration instead of this Expo-only wrapper.
@MainActor
public enum ExpoMediaSupport {
  private static var attempted = false

  @discardableResult
  public static func startFromBundle(_ bundle: Bundle = .main) throws -> VoIPApplication {
    if !attempted {
      attempted = true
      let settings = bundle.object(forInfoDictionaryKey: "VoIPSDK") as? [String: Any]
      let requested = settings?["mediaAdapter"] as? String ?? "webrtc"
      if requested != ExpoMediaSelection.name {
        NSLog("[VoIPSDK] Media adapter configuration differs from the pod selection; regenerate the iOS project and pods.")
      }
      do { try ConversationClient.registerMediaAdapter(selectedMediaAdapter()) }
      catch { NSLog("[VoIPSDK] The selected media adapter could not register before client creation.") }
    }
    // Media configuration must never prevent required native PushKit reporting.
    return try VoIPApplication.startFromBundle(bundle)
  }
}
