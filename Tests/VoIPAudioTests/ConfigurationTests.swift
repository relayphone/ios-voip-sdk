import Testing
import VoIPCore

@testable import VoIPAudio

@Suite("Configuration")
@VoIPActor
struct ConfigurationTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let name: String
    var configuration = AudioSessionConfiguration()
    let call: Call
    let options: CategoryOptions

    var testDescription: String { name }
  }

  nonisolated static let cases: [Case] = [
    Case(
      name: "a voice call uses hands-free and A2DP Bluetooth", call: voiceCall,
      options: [.allowBluetoothHFP, .allowBluetoothA2DP]),
    Case(
      name: "a video call defaults to the speaker", call: videoCall,
      options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]),
    Case(
      name: "the app leaves out A2DP and adds AirPlay",
      configuration: AudioSessionConfiguration(allowsBluetoothA2DP: false, allowsAirPlay: true),
      call: voiceCall, options: [.allowBluetoothHFP, .allowAirPlay]),
    Case(
      name: "the app keeps video calls on the receiver",
      configuration: AudioSessionConfiguration(videoCallsDefaultToSpeaker: false),
      call: videoCall, options: [.allowBluetoothHFP, .allowBluetoothA2DP]),
  ]

  @Test(arguments: cases)
  func setsPlayAndRecordInVoiceChatModeWithTheCallsOptions(_ row: Case) throws {
    let attached = Attached(configuration: row.configuration)
    try attached.adapter.configure(for: row.call)
    #expect(attached.session.records == [.setCategory(row.options)])
  }

  @Test func aRefusedConfigurationThrows() {
    let attached = Attached()
    attached.session.failsConfiguration = true
    #expect(throws: AudioSessionError.configurationFailed) {
      try attached.adapter.configure(for: voiceCall)
    }
  }

  @Test func configuringOnlySetsTheCategory() throws {
    let attached = Attached()
    try attached.adapter.configure(for: videoCall)
    try attached.adapter.configure(for: voiceCall)
    #expect(
      attached.session.records == [
        .setCategory([.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]),
        .setCategory([.allowBluetoothHFP, .allowBluetoothA2DP]),
      ])
    #expect(attached.events.isEmpty)
  }
}
