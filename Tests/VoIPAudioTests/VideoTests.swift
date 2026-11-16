import Testing
import VoIPCore

@testable import VoIPAudio

@Suite("Video mode and route ownership") @VoIPActor
struct VideoTests {
  @Test func upgradeAndDowngradeOnlyReverseOwnedSpeakerRoute() throws {
    let h = Attached()
    try h.adapter.updateVideo(for: videoCall)
    #expect(h.session.records == [.videoMode(true), .overrideOutput(toSpeaker: true)])
    h.session.current.outputs = [.speaker]
    h.notifications.post(.routeOverride)
    try h.adapter.updateVideo(for: voiceCall)
    #expect(h.session.records.suffix(2) == [.videoMode(false), .overrideOutput(toSpeaker: false)])
    #expect(h.events.isEmpty)
  }

  @Test func explicitReceiverChoicePreventsAutomaticSpeaker() throws {
    let h = Attached()
    let receiver = try #require(h.adapter.list.routes.first { $0.kind == .builtInReceiver })
    try h.adapter.selectRoute(receiver.id)
    let before = h.session.records.count
    try h.adapter.updateVideo(for: videoCall)
    #expect(Array(h.session.records.dropFirst(before)) == [.videoMode(true)])
  }

  @Test func anExplicitSpeakerChoiceAfterUpgradeIsNotReversed() throws {
    let h = Attached()
    try h.adapter.updateVideo(for: videoCall)
    h.session.current.outputs = [.speaker]
    h.notifications.post(.routeOverride)
    try h.adapter.selectRoute(RouteList.speakerID)
    let before = h.session.records.count
    try h.adapter.updateVideo(for: voiceCall)
    #expect(Array(h.session.records.dropFirst(before)) == [.videoMode(false)])
  }

  @Test(arguments: [Port.headphones, .airPodsHFP, .speakerA2DP])
  func externalRoutesAlwaysWin(output: Port) throws {
    let h = Attached(ports: .init(inputs: [.builtInMic], outputs: [output]))
    try h.adapter.updateVideo(for: videoCall)
    try h.adapter.updateVideo(for: voiceCall)
    #expect(h.session.records == [.videoMode(true), .videoMode(false)])
  }

  @Test func routeChangeAfterUpgradeClearsOwnership() throws {
    let h = Attached()
    try h.adapter.updateVideo(for: videoCall)
    h.session.current.outputs = [.headphones]
    h.notifications.post(.routesChanged)
    h.session.current.outputs = [.speaker]
    h.notifications.post(.routesChanged)
    let before = h.session.records.count
    try h.adapter.updateVideo(for: voiceCall)
    #expect(Array(h.session.records.dropFirst(before)) == [.videoMode(false)])
  }

  @Test func systemReceiverSelectionIsRespected() throws {
    let h = Attached()
    h.notifications.post(.routeOverride)
    try h.adapter.updateVideo(for: videoCall)
    #expect(h.session.records == [.videoMode(true)])
  }
  @Test func categoryNotificationsDoNotTurnAnOwnedDowngradeIntoAUserChoice() throws {
    let h = Attached()
    try h.adapter.updateVideo(for: videoCall)
    h.session.current.outputs = [.speaker]
    h.notifications.post(.routeOverride)
    try h.adapter.updateVideo(for: voiceCall)
    h.session.current.outputs = [.receiver]
    h.notifications.post(.routesChanged)
    h.notifications.post(.routeOverride)
    let before = h.session.records.count
    try h.adapter.updateVideo(for: videoCall)
    #expect(
      Array(h.session.records.dropFirst(before)) == [
        .videoMode(true), .overrideOutput(toSpeaker: true),
      ])
  }
}
