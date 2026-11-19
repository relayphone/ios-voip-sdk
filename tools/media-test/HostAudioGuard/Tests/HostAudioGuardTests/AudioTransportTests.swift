import CoreAudio
import Testing

@testable import HostAudioGuard

@Test(arguments: [
  (kAudioDeviceTransportTypeBuiltIn, "built-in"),
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
