#if os(iOS)
  import Foundation
  import LiveCommunicationKit
  import VoIPCore

  /// A LiveCommunicationKit handle, which shares its name with the SDK's handle.
  typealias SystemHandle = LiveCommunicationKit.Handle

  extension ConversationManager.Configuration {
    /// The manager's configuration for the app's configuration.
    ///
    /// Each call is its own conversation group, unless calls can be merged.
    init(_ configuration: VoIPConfiguration) {
      let calls = max(1, configuration.maximumCalls)
      self.init(
        ringtoneName: configuration.ringtoneSound,
        iconTemplateImageData: configuration.iconTemplateImageData,
        maximumConversationGroups: calls,
        maximumConversationsPerConversationGroup:
          configuration.capabilities.contains(.merging) ? calls : 1,
        includesConversationInRecents: configuration.includesCallsInRecents,
        supportsVideo: configuration.supportsVideo,
        supportedHandleTypes: Set(configuration.supportedHandleTypes.map(SystemHandle.Kind.init)))
    }
  }

  extension Conversation.Capabilities {
    /// The actions a call supports in the app's configuration, and video when it has video.
    init(_ capabilities: VoIPConfiguration.Capabilities, hasVideo: Bool) {
      self = []
      if capabilities.contains(.holding) { insert(.pausing) }
      if capabilities.contains(.playingTones) { insert(.playingTones) }
      if capabilities.contains(.merging) { formUnion([.merging, .unmerging]) }
      if hasVideo { insert(.video) }
    }
  }

  extension Conversation.EndedReason {
    /// The reason LiveCommunicationKit shows, such as in Recents, for a call that ended without
    /// the user ending it on this device.
    init(_ reason: EndReason) {
      self =
        switch reason {
        case .endedRemotely: .remoteEnded
        case .unanswered: .unanswered
        case .answeredElsewhere: .joinedElsewhere
        case .declinedElsewhere: .declinedElsewhere
        case .failed, .filtered: .failed
        // The SDK ends a call on this device with an end action, not a report.
        case .endedHere: .remoteEnded
        }
    }
  }

  extension SystemHandle.Kind {
    init(_ kind: VoIPCore.Handle.Kind) {
      self =
        switch kind {
        case .phoneNumber: .phoneNumber
        case .emailAddress: .emailAddress
        case .generic: .generic
        }
    }
  }

  extension VoIPCore.Handle.Kind {
    init(_ kind: SystemHandle.Kind) {
      self =
        switch kind {
        case .phoneNumber: .phoneNumber
        case .emailAddress: .emailAddress
        case .generic: .generic
        @unknown default: .generic
        }
    }
  }

  extension [Party] {
    /// Every handle of every party, each with its party's display name, so that the system can
    /// match any of them to a contact.
    var systemHandles: [SystemHandle] {
      flatMap { party in
        party.handles.map {
          SystemHandle(type: .init($0.kind), value: $0.value, displayName: party.displayName)
        }
      }
    }
  }

  extension Party {
    /// The party that a system handle names, such as one the user called from Recents.
    ///
    /// A value that isn't valid for its kind, such as a phone number that isn't in E.164 format,
    /// becomes a generic handle.
    init?(_ handle: SystemHandle) {
      let kind = VoIPCore.Handle.Kind(handle.type)
      guard
        let presented = (try? VoIPCore.Handle(kind: kind, value: handle.value))
          ?? (try? VoIPCore.Handle(kind: .generic, value: handle.value))
      else { return nil }
      self.init(
        handle: presented, displayName: handle.displayName.isEmpty ? nil : handle.displayName)
    }
  }
#endif
