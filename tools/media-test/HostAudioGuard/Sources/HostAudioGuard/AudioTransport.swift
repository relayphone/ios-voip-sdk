import CoreAudio

enum AudioTransport: Equatable {
  case virtual
  case aggregate
  case hardware(String)

  init(_ code: UInt32) {
    self =
      switch code {
      case kAudioDeviceTransportTypeVirtual: .virtual
      case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: .aggregate
      case kAudioDeviceTransportTypeBuiltIn: .hardware("built-in")
      case kAudioDeviceTransportTypeUSB: .hardware("USB")
      case kAudioDeviceTransportTypeBluetooth: .hardware("Bluetooth")
      case kAudioDeviceTransportTypeBluetoothLE: .hardware("Bluetooth LE")
      case kAudioDeviceTransportTypeHDMI: .hardware("HDMI")
      case kAudioDeviceTransportTypeDisplayPort: .hardware("DisplayPort")
      case kAudioDeviceTransportTypeAirPlay: .hardware("AirPlay")
      case kAudioDeviceTransportTypeThunderbolt: .hardware("Thunderbolt")
      case kAudioDeviceTransportTypeFireWire: .hardware("FireWire")
      case kAudioDeviceTransportTypePCI: .hardware("PCI")
      default: .hardware("unknown transport \(code)")
      }
  }

  var label: String {
    switch self {
    case .virtual: "virtual"
    case .aggregate: "aggregate"
    case .hardware(let label): label
    }
  }
}

struct AudioRoute {
  struct Hardware {
    let id: AudioObjectID
    let transport: String
  }

  enum Failure: Error {
    case aggregateCycle(AudioObjectID)
  }

  let transport: AudioTransport
  let hardware: Hardware?

  init(
    _ id: AudioObjectID,
    transport readTransport: (AudioObjectID) throws -> AudioTransport,
    members: (AudioObjectID) throws -> [AudioObjectID],
    ancestors: Set<AudioObjectID> = []
  ) throws {
    guard !ancestors.contains(id) else { throw Failure.aggregateCycle(id) }
    transport = try readTransport(id)
    switch transport {
    case .virtual:
      hardware = nil
    case .hardware(let label):
      hardware = Hardware(id: id, transport: label)
    case .aggregate:
      for member in try members(id) {
        let memberRoute = try AudioRoute(
          member, transport: readTransport, members: members, ancestors: ancestors.union([id]))
        if let memberHardware = memberRoute.hardware {
          hardware = memberHardware
          return
        }
      }
      hardware = nil
    }
  }
}
