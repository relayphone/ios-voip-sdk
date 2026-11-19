import CoreAudio
import Testing

@testable import HostAudioGuard

@Test(arguments: [
  (kAudioDeviceTransportTypeUSB, "USB"),
  (kAudioDeviceTransportTypeBluetooth, "Bluetooth"),
  (kAudioDeviceTransportTypeBluetoothLE, "Bluetooth LE"),
  (kAudioDeviceTransportTypeHDMI, "HDMI"),
  (kAudioDeviceTransportTypeDisplayPort, "DisplayPort"),
  (kAudioDeviceTransportTypeAirPlay, "AirPlay"),
  (kAudioDeviceTransportTypeThunderbolt, "Thunderbolt"),
  (kAudioDeviceTransportTypeFireWire, "FireWire"),
  (kAudioDeviceTransportTypePCI, "PCI"),
  (kAudioDeviceTransportTypeUnknown, "unknown transport 0"),
  (UInt32.max, "unknown transport 4294967295"),
])
func unsafeTransport(_ code: UInt32, _ label: String) {
  #expect(AudioTransport(code) == .hardware(label))
}

@Test func virtualTransportsAndVirtualOnlyAggregatesAreAllowed() throws {
  let route = try AudioRoute(
    1,
    transport: { id in
      AudioTransport(
        id == 1 ? kAudioDeviceTransportTypeAggregate : kAudioDeviceTransportTypeVirtual)
    },
    members: { _ in [2, 3] })
  #expect(AudioTransport(kAudioDeviceTransportTypeVirtual) == .virtual)
  #expect(AudioTransport(kAudioDeviceTransportTypeAutoAggregate) == .aggregate)
  #expect(route.transport == .aggregate)
  #expect(route.hardware == nil)
}

@Test func nestedAggregateBlocksOnHardwareOrUnknownMembers() throws {
  for (code, label) in [
    (kAudioDeviceTransportTypeUSB, "USB"),
    (UInt32.max, "unknown transport 4294967295"),
  ] {
    let route = try AudioRoute(
      1,
      transport: { id in
        switch id {
        case 1, 2: .aggregate
        case 3: .virtual
        default: AudioTransport(code)
        }
      },
      members: { id in id == 1 ? [2] : [3, 4] })
    #expect(route.hardware?.id == 4)
    #expect(route.hardware?.transport == label)
  }
}

@Test func anAggregateCycleCannotQualify() {
  #expect(throws: AudioRoute.Failure.self) {
    try AudioRoute(1, transport: { _ in .aggregate }, members: { _ in [1] })
  }
}

private let hostedEnvironment = ["GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"]

@Test(arguments: [
  (
    AudioDirection.input,
    AudioDeviceIdentity(
      name: "MacBook Pro Microphone", uid: "BuiltInMicrophoneDevice", modelUID: "Digital Mic")
  ),
  (
    AudioDirection.output,
    AudioDeviceIdentity(
      name: "MacBook Pro Speakers", uid: "BuiltInSpeakerDevice", modelUID: "Speaker")
  ),
])
func spoofedHostedEnvironmentRejectsMacBuiltInDevices(
  _ direction: AudioDirection, _ physical: AudioDeviceIdentity
) throws {
  let builtIn = try AudioRoute(
    1, transport: { _ in AudioTransport(kAudioDeviceTransportTypeBuiltIn) }, members: { _ in [] })
  #expect(builtIn.transport == .builtIn)
  #expect(builtIn.hardware != nil)
  let policy = HostedAudioPolicy(environment: hostedEnvironment)
  #expect(policy.isHosted)
  #expect(!policy.allows(physical, directions: [direction], route: builtIn))
}

@Test(arguments: [(AudioDirection.input, "AVIODevice 2"), (AudioDirection.output, "AVIODevice")])
func hostedActivityAcceptsTheTwoPinnedUIDsInEitherDirection(
  _ direction: AudioDirection, _ uid: String
) throws {
  let name = "Apple Virtual Sound Device"
  let guest = AudioDeviceIdentity(name: name, uid: uid, modelUID: nil)
  let otherDirection: AudioDirection = direction == .input ? .output : .input
  let policy = HostedAudioPolicy(environment: hostedEnvironment)
  for transport: AudioTransport in [.builtIn, .virtual, AudioTransport(.max)] {
    let route = try AudioRoute(1, transport: { _ in transport }, members: { _ in [] })
    let allowed = transport == .builtIn || transport == .virtual
    #expect(policy.allows(guest, directions: [direction], route: route) == allowed)
    #expect(policy.allows(guest, directions: [otherDirection], route: route) == allowed)
    #expect(!policy.allows(guest, directions: [.input, .output], route: route))
    #expect(
      !policy.allows(
        .init(name: "other-name", uid: uid, modelUID: nil),
        directions: [direction], route: route))
    #expect(
      !policy.allows(
        .init(name: name, uid: "AVIODevice 3", modelUID: nil),
        directions: [direction], route: route))
  }
  let aggregate = try AudioRoute(
    1, transport: { $0 == 1 ? .aggregate : .builtIn }, members: { _ in [2] })
  #expect(!policy.allows(guest, directions: [direction], route: aggregate))
  let builtIn = try AudioRoute(1, transport: { _ in .builtIn }, members: { _ in [] })
  for environment in [[:], ["GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "self-hosted"]] {
    #expect(
      !HostedAudioPolicy(environment: environment).allows(
        guest, directions: [direction], route: builtIn))
  }
}
