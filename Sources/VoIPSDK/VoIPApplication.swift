import Foundation

/// The config plugin's plist schema, decoded before any platform services start.
struct VoIPBundleConfiguration: Decodable {
  let ringtoneName: String?
  let iconTemplateImageName: String?
  let maximumConversationGroups: Int
  let maximumConversationsPerConversationGroup: Int
  let includesCallsInRecents: Bool
  let supportsVideo: Bool
  let unhandledAction: UnhandledActionPolicy
  let simulatorSupport: Bool

  private enum CodingKeys: String, CodingKey {
    case ringtoneName, iconTemplateImageName, maximumConversationGroups, maximumConversationsPerConversationGroup
    case includesCallsInRecents, supportsVideo, unhandledAction, simulatorSupport
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    ringtoneName = try values.decodeIfPresent(String.self, forKey: .ringtoneName)
    iconTemplateImageName = try values.decodeIfPresent(String.self, forKey: .iconTemplateImageName)
    maximumConversationGroups = try values.decodeIfPresent(Int.self, forKey: .maximumConversationGroups) ?? 2
    maximumConversationsPerConversationGroup = try values.decodeIfPresent(Int.self, forKey: .maximumConversationsPerConversationGroup) ?? 2
    includesCallsInRecents = try values.decodeIfPresent(Bool.self, forKey: .includesCallsInRecents) ?? true
    supportsVideo = try values.decodeIfPresent(Bool.self, forKey: .supportsVideo) ?? true
    unhandledAction = try values.decodeIfPresent(UnhandledActionPolicy.self, forKey: .unhandledAction) ?? .fail
    simulatorSupport = try values.decodeIfPresent(Bool.self, forKey: .simulatorSupport) ?? true
    guard maximumConversationGroups > 0, maximumConversationsPerConversationGroup > 0 else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Conversation limits must be positive"))
    }
  }
}

#if canImport(LiveCommunicationKit) && (os(iOS) || os(watchOS))
#if os(iOS)
import UIKit
#endif

/// Start in application launch, before a UI scene or JavaScript is required.
@MainActor
public final class VoIPApplication {
  public struct Configuration: Sendable, Equatable {
    public var client: ConversationClient.Configuration
    public var simulatorSupport: Bool
    public init(client: ConversationClient.Configuration = .init(), simulatorSupport: Bool = true) {
      self.client = client; self.simulatorSupport = simulatorSupport
    }

    /// Reads the config plugin's VoIPSDK Info.plist dictionary.
    public static func fromBundle(_ bundle: Bundle = .main) throws(VoIPStartupError) -> Configuration {
      let info: VoIPBundleConfiguration
      do {
        let data = try PropertyListSerialization.data(
          fromPropertyList: bundle.object(forInfoDictionaryKey: "VoIPSDK") ?? [String: String](),
          format: .binary, options: 0)
        info = try PropertyListDecoder().decode(VoIPBundleConfiguration.self, from: data)
      } catch { throw VoIPStartupError.invalidConfiguration }
      let ringtone = info.ringtoneName
      var iconData: Data?
      if let name = info.iconTemplateImageName, !name.isEmpty {
        #if os(iOS)
        iconData = UIImage(named: name, in: bundle, compatibleWith: nil)?.pngData()
        #else
        if let url = bundle.url(forResource: name, withExtension: nil) { iconData = try? Data(contentsOf: url) }
        #endif
        if iconData == nil { NSLog("VoIPSDK: configured icon could not be loaded; using the system icon.") }
      }
      return Configuration(client: .init(
        ringtoneName: ringtone == "default" || ringtone == "" ? nil : ringtone,
        iconTemplateImageData: iconData,
        maximumConversationGroups: info.maximumConversationGroups,
        maximumConversationsPerGroup: info.maximumConversationsPerConversationGroup,
        includesConversationInRecents: info.includesCallsInRecents,
        supportsVideo: info.supportsVideo, unhandledAction: info.unhandledAction),
        simulatorSupport: info.simulatorSupport)
    }
  }

  public private(set) static var current: VoIPApplication?
  private static var starting = false
  public let client: ConversationClient
  public let pushService: PushService
  private let configuration: Configuration
  private init(client: ConversationClient, configuration: Configuration) {
    self.client = client; self.configuration = configuration
    pushService = PushService(client: client)
  }

  /// Idempotent for the same launch configuration. A failed registration can retry
  /// without creating another manager or receiver.
  @discardableResult
  public static func start(configuration: Configuration = .init(), mediaAdapter: (any MediaAdapter)? = nil,
                           audioPolicy: AudioActivationPolicy = .standard) throws(VoIPStartupError) -> VoIPApplication {
    try ProcessSDKOwnership.claim()
    if let current {
      guard current.configuration == configuration else { throw VoIPStartupError.alreadyConfigured }
      _ = try ConversationClient.forApplication(configuration: configuration.client,
        mediaAdapter: mediaAdapter, audioPolicy: audioPolicy)
      current.client.finishLaunch()
      try startPushService(current.pushService)
      return current
    }
    guard !starting else { throw VoIPStartupError.alreadyConfigured }
    starting = true
    defer { starting = false }
    do { try SimulatorSupport.configure(enabled: configuration.simulatorSupport) }
    catch { throw VoIPStartupError.simulatorAlreadyActivated }
    let client = try ConversationClient.forApplication(configuration: configuration.client,
      mediaAdapter: mediaAdapter, audioPolicy: audioPolicy)
    let application = VoIPApplication(client: client, configuration: configuration)
    current = application
    client.finishLaunch()
    try startPushService(application.pushService)
    return application
  }

  @discardableResult
  public static func startFromBundle(_ bundle: Bundle = .main, mediaAdapter: (any MediaAdapter)? = nil,
                                     audioPolicy: AudioActivationPolicy = .standard) throws(VoIPStartupError) -> VoIPApplication {
    try start(configuration: Configuration.fromBundle(bundle), mediaAdapter: mediaAdapter, audioPolicy: audioPolicy)
  }

  private static func startPushService(_ service: PushService) throws(VoIPStartupError) {
    do { try service.start() }
    catch { throw VoIPStartupError.pushRegistration(error) }
  }
}
#endif
