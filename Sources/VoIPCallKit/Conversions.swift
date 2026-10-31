#if os(iOS)
  import CallKit
  import Foundation
  #if SWIFT_PACKAGE
    import VoIPCore
  #endif

  extension CXProviderConfiguration {
    /// The provider's configuration for the app's configuration.
    ///
    /// Each call is its own call group, unless calls can be merged.
    convenience init(_ configuration: VoIPConfiguration) {
      self.init()
      let calls = max(1, configuration.maximumCalls)
      maximumCallGroups = calls
      maximumCallsPerCallGroup = configuration.capabilities.contains(.merging) ? calls : 1
      supportsVideo = configuration.supportsVideo
      includesCallsInRecents = configuration.includesCallsInRecents
      ringtoneSound = configuration.ringtoneSound
      iconTemplateImageData = configuration.iconTemplateImageData
      supportedHandleTypes = Set(configuration.supportedHandleTypes.map(CXHandle.HandleType.init))
    }
  }

  extension CXCallUpdate {
    /// A call's details for the system: its first party, the actions it supports in the app's
    /// configuration, and whether it has video.
    ///
    /// CallKit presents one handle for a call, so the update names the first party's presented
    /// handle, with the party's display name as the caller's name.
    convenience init(_ call: Call, capabilities: VoIPConfiguration.Capabilities) {
      self.init()
      if let party = call.parties.first {
        remoteHandle = CXHandle(party.presentedHandle)
        localizedCallerName = party.displayName
      }
      supportsHolding = capabilities.contains(.holding)
      supportsDTMF = capabilities.contains(.playingTones)
      supportsGrouping = capabilities.contains(.merging)
      supportsUngrouping = capabilities.contains(.merging)
      hasVideo = call.hasVideo
    }
  }

  extension CXCallEndedReason {
    /// The reason CallKit shows, such as in Recents, for a call that ended without the user
    /// ending it on this device.
    init(_ reason: EndReason) {
      self =
        switch reason {
        case .endedRemotely: .remoteEnded
        case .unanswered: .unanswered
        case .answeredElsewhere: .answeredElsewhere
        case .declinedElsewhere: .declinedElsewhere
        case .failed, .filtered: .failed
        // The SDK ends a call on this device with an end action, not a report.
        case .endedHere: .remoteEnded
        }
    }
  }

  extension CXHandle {
    convenience init(_ handle: Handle) {
      self.init(type: HandleType(handle.kind), value: handle.value)
    }
  }

  extension CXHandle.HandleType {
    init(_ kind: Handle.Kind) {
      self =
        switch kind {
        case .phoneNumber: .phoneNumber
        case .emailAddress: .emailAddress
        case .generic: .generic
        }
    }
  }
#endif
