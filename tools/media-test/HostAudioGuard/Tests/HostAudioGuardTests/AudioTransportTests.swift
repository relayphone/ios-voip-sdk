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
private let exampleGuest = AudioDeviceIdentity(uid: "test-guest-uid", modelUID: "test-model")

@Test(arguments: [
  AudioDeviceIdentity(uid: "BuiltInMicrophoneDevice", modelUID: "Digital Mic"),
  AudioDeviceIdentity(uid: "BuiltInSpeakerDevice", modelUID: "Speaker"),
])
func spoofedHostedEnvironmentRejectsMacBuiltInDevices(_ physical: AudioDeviceIdentity) throws {
  let builtIn = try AudioRoute(
    1, transport: { _ in AudioTransport(kAudioDeviceTransportTypeBuiltIn) }, members: { _ in [] })
  #expect(builtIn.transport == .builtIn)
  #expect(builtIn.hardware != nil)
  #expect(!HostedAudioPolicy(environment: hostedEnvironment).allows(physical, route: builtIn))
  let policy = HostedAudioPolicy(environment: hostedEnvironment, pins: [exampleGuest])
  #expect(policy.isHosted)
  #expect(!policy.allows(physical, route: builtIn))
}

@Test func hostedActivityRequiresThePinnedUIDAndModelAndAKnownTransport() throws {
  let policy = HostedAudioPolicy(environment: hostedEnvironment, pins: [exampleGuest])
  for transport: AudioTransport in [.builtIn, .virtual, AudioTransport(.max)] {
    let route = try AudioRoute(1, transport: { _ in transport }, members: { _ in [] })
    #expect(
      policy.allows(exampleGuest, route: route) == (transport == .builtIn || transport == .virtual))
    #expect(!policy.allows(.init(uid: "other-uid", modelUID: exampleGuest.modelUID), route: route))
    #expect(!policy.allows(.init(uid: exampleGuest.uid, modelUID: nil), route: route))
    #expect(!policy.allows(.init(uid: exampleGuest.uid, modelUID: "other-model"), route: route))
  }
  let aggregate = try AudioRoute(
    1, transport: { $0 == 1 ? .aggregate : .builtIn }, members: { _ in [2] })
  #expect(!policy.allows(exampleGuest, route: aggregate))
}
