import CoreAudio

enum AudioTransport: Equatable {
  case virtual
  case aggregate
  case builtIn
  case hardware(String)

  init(_ code: UInt32) {
    self =
      switch code {
      case kAudioDeviceTransportTypeVirtual: .virtual
      case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: .aggregate
      case kAudioDeviceTransportTypeBuiltIn: .builtIn
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
    case .builtIn: "built-in"
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
    case .builtIn:
      hardware = Hardware(id: id, transport: transport.label)
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

enum AudioDirection: String, Sendable {
  case input
  case output
}

struct AudioDeviceIdentity: Sendable {
  let name: String
  let uid: String
  let modelUID: String?
}

struct HostedAudioPolicy {
  // GitHub-hosted macOS exposes two Apple guest audio endpoints with no model UID.
  private static let hostedDeviceUIDs: [AudioDirection: String] = [
    .input: "AVIODevice 2",
    .output: "AVIODevice",
  ]
  let isHosted: Bool

  init(environment: [String: String]) {
    isHosted =
      environment["GITHUB_ACTIONS"] == "true"
      && environment["RUNNER_ENVIRONMENT"] == "github-hosted"
  }

  func allows(
    _ identity: AudioDeviceIdentity, directions: [AudioDirection], route: AudioRoute
  ) -> Bool {
    guard isHosted else { return route.hardware == nil }
    guard identity.name == "Apple Virtual Sound Device", !directions.isEmpty,
      directions.allSatisfy({ Self.hostedDeviceUIDs[$0] == identity.uid })
    else { return false }
    return route.transport == .builtIn || route.hardware == nil
  }
}
