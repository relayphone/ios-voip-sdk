#if os(iOS)
  import CallKit
  import Foundation
  import Testing
  import VoIPCore

  @testable import VoIPCallKit

  @Suite struct ConversionTests {
    @Test func configuresTheProviderWithTheDefaults() {
      let provider = CXProviderConfiguration(VoIPConfiguration())
      #expect(provider.maximumCallGroups == 2)
      #expect(provider.maximumCallsPerCallGroup == 1)
      #expect(!provider.supportsVideo)
      #expect(provider.includesCallsInRecents)
      #expect(provider.ringtoneSound == nil)
      #expect(provider.iconTemplateImageData == nil)
      #expect(provider.supportedHandleTypes == [.phoneNumber, .emailAddress, .generic])
    }

    @Test func configuresTheProviderWithTheAppsChoices() {
      let icon = Data([0x89, 0x50, 0x4E, 0x47])
      // CallKit keeps a ringtone only when the app's bundle has the sound, which tests can't
      // provide.
      let provider = CXProviderConfiguration(
        VoIPConfiguration(
          capabilities: [.holding, .merging], maximumCalls: 3,
          supportedHandleTypes: [.phoneNumber], supportsVideo: true,
          includesCallsInRecents: false, iconTemplateImageData: icon))
      #expect(provider.maximumCallGroups == 3)
      #expect(provider.maximumCallsPerCallGroup == 3)
      #expect(provider.supportsVideo)
      #expect(!provider.includesCallsInRecents)
      #expect(provider.iconTemplateImageData == icon)
      #expect(provider.supportedHandleTypes == [.phoneNumber])
    }

    @Test func presentsAtLeastOneCallGroup() {
      #expect(CXProviderConfiguration(VoIPConfiguration(maximumCalls: 0)).maximumCallGroups == 1)
    }

    @Test(arguments: [
      (Handle.Kind.phoneNumber, "+14155550123", CXHandle.HandleType.phoneNumber),
      (.emailAddress, "alice@example.com", .emailAddress), (.generic, "alice-42", .generic),
    ])
    func reportsTheFirstPartysPresentedHandleAndName(
      _ kind: Handle.Kind, _ value: String, _ type: CXHandle.HandleType
    ) throws {
      let alice = try Party(
        handles: [Handle(kind: kind, value: value), Handle(kind: .generic, value: "other")],
        displayName: "Alice")
      let bob = try Party(handle: Handle(kind: .phoneNumber, value: "+442071838750"))
      let update = CXCallUpdate(
        Call(
          id: CallID(rawValue: "call"), isIncoming: true, parties: [alice, bob], status: .ringing,
          hasVideo: true),
        capabilities: [.holding, .playingTones])
      #expect(update.remoteHandle?.type == type)
      #expect(update.remoteHandle?.value == value)
      #expect(update.localizedCallerName == "Alice")
      #expect(update.hasVideo)
      #expect(update.supportsHolding)
      #expect(update.supportsDTMF)
      #expect(!update.supportsGrouping)
      #expect(!update.supportsUngrouping)
    }

    @Test func reportsACallWithoutAPartyWithoutAHandle() {
      let update = CXCallUpdate(
        Call(id: CallID(rawValue: "call"), isIncoming: true, parties: [], status: .ringing),
        capabilities: [.merging])
      #expect(update.remoteHandle == nil)
      #expect(update.localizedCallerName == nil)
      #expect(!update.hasVideo)
      #expect(!update.supportsHolding)
      #expect(!update.supportsDTMF)
      #expect(update.supportsGrouping)
      #expect(update.supportsUngrouping)
    }

    @Test(arguments: [
      (EndReason.endedRemotely, CXCallEndedReason.remoteEnded),
      (.unanswered, .unanswered), (.answeredElsewhere, .answeredElsewhere),
      (.declinedElsewhere, .declinedElsewhere), (.failed(.media), .failed),
      (.filtered(.doNotDisturb), .failed), (.endedHere, .remoteEnded),
    ])
    func mapsEndReasons(_ reason: EndReason, _ ended: CXCallEndedReason) {
      #expect(CXCallEndedReason(reason) == ended)
    }
  }
#endif
