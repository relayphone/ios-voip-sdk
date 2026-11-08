import Foundation

/// The module's settings, which the config plugin writes to the app's Info.plist.
struct Settings: Sendable {
  /// How the SDK presents and controls calls.
  let configuration: VoIPConfiguration

  /// The `mediaAdapter` plugin option: `webrtc` or `none`.
  enum MediaAdapter: String, Sendable { case webrtc, none }
  let mediaAdapter: MediaAdapter

  /// Whether a start or join that no handler received is placed anyway.
  let acceptsUnhandledActions: Bool

  /// The App Group in which the app's Focus filter records its state, from the `focusFilter`
  /// plugin option.
  let focusAppGroup: String?

  /// The settings in the main bundle's Info.plist.
  static let main = Settings(Bundle.main.infoDictionary ?? [:])

  init(_ info: [String: Any]) {
    func seconds(_ key: String) -> Duration? {
      (info[key] as? Int).map { .seconds(max(1, $0)) }
    }
    let defaults = Deadlines()
    let ringtone = info["VoIPConversationsDefaultRingtone"] as? String
    let icon = (info["VoIPConversationsIconTemplate"] as? String).flatMap {
      Bundle.main.url(forResource: $0, withExtension: nil)
    }
    configuration = VoIPConfiguration(
      supportsVideo: true,
      includesCallsInRecents: info["VoIPConversationsIncludesCallsInRecents"] as? Bool ?? true,
      ringtoneSound: ringtone == "default" ? nil : ringtone,
      iconTemplateImageData: icon.flatMap { try? Data(contentsOf: $0) },
      deadlines: Deadlines(
        ring: seconds("VoIPConversationsIncomingCallTimeout") ?? defaults.ring,
        connect: seconds("VoIPConversationsFulfillAnswerCallTimeout") ?? defaults.connect))
    mediaAdapter =
      MediaAdapter(rawValue: info["VoIPConversationsMediaAdapter"] as? String ?? "") ?? .webrtc
    acceptsUnhandledActions = info["VoIPConversationsUnhandledAction"] as? String == "accept"
    focusAppGroup = info["VoIPConversationsFocusAppGroup"] as? String
  }

  /// The TypeScript API's `ConversationCapabilities`, the same for every call.
  var capabilities: JSONValue {
    .object([
      "hold": .bool(configuration.capabilities.contains(.holding)),
      "merge": .bool(configuration.capabilities.contains(.merging)),
      "tones": .bool(configuration.capabilities.contains(.playingTones)),
      "video": .bool(configuration.supportsVideo),
    ])
  }
}
