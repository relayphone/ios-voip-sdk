import CoreAudio
import Foundation
import Synchronization

private enum GuardError: Error, CustomStringConvertible {
  case property(AudioObjectID, AudioObjectPropertySelector, OSStatus)
  case propertySize(AudioObjectID, AudioObjectPropertySelector, UInt32)
  case unreadableAggregate(AudioObjectID)
  case active(Device, AudioRoute.Hardware)
  case routeChanged(String)
  case aggregateChanged(AudioObjectID)

  var description: String {
    switch self {
    case .property(let device, let selector, let status):
      return "Core Audio property \(selector) on object \(device) failed (\(status))"
    case .propertySize(let device, let selector, let size):
      return "Core Audio property \(selector) on object \(device) returned \(size) bytes"
    case .unreadableAggregate(let id):
      return "Could not resolve the sub-devices of aggregate audio device \(id)"
    case .active(let device, let hardware):
      let endpoint =
        hardware.id == device.id
        ? hardware.transport
        : "aggregate contains \(deviceName(hardware.id)) (\(hardware.transport))"
      return
        "Host audio active on default \(device.directions) device \(device.name) (\(device.id)) (\(endpoint))"
    case .routeChanged(let direction):
      return "Default host audio \(direction) changed during monitoring"
    case .aggregateChanged(let id):
      return "Host audio aggregate \(deviceName(id)) (\(id)) changed during monitoring"
    }
  }
}

private struct Device: Sendable {
  let id: AudioObjectID
  let directions: String
  let name: String
}

private struct Violation: Error {
  let reason: GuardError
  var time = Date.now
}

private final class DeviceEvents: Sendable {
  private let first = Mutex<Violation?>(nil)
  private let pending = Mutex<[AudioObjectID: Date]>([:])

  func routeChanged(_ reason: GuardError) {
    let violation = Violation(reason: reason)
    first.withLock { if $0 == nil { $0 = violation } }
  }

  func recordActivity(_ id: AudioObjectID) {
    let now = Date.now
    pending.withLock { if $0[id] == nil { $0[id] = now } }
  }

  func takeActivity() -> [AudioObjectID: Date] {
    pending.withLock { state in
      let activity = state
      state.removeAll(keepingCapacity: true)
      return activity
    }
  }

  func checkRoutes() throws(Violation) {
    if let violation = first.withLock({ $0 }) { throw violation }
  }
}

private let system = AudioObjectID(kAudioObjectSystemObject)
private let defaults: [(String, AudioObjectPropertySelector)] = [
  ("input", kAudioHardwarePropertyDefaultInputDevice),
  ("output", kAudioHardwarePropertyDefaultOutputDevice),
]
private let running = kAudioDevicePropertyDeviceIsRunningSomewhere

private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
  .init(
    mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
}

private func read(
  _ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
  qualifier: UnsafeRawPointer? = nil, qualifierSize: UInt32 = 0
) throws(GuardError) -> UInt32 {
  var property = address(selector)
  var value: UInt32 = 0
  var size = UInt32(MemoryLayout.size(ofValue: value))
  let status = AudioObjectGetPropertyData(id, &property, qualifierSize, qualifier, &size, &value)
  guard status == noErr else { throw .property(id, selector, status) }
  guard size == MemoryLayout.size(ofValue: value) else { throw .propertySize(id, selector, size) }
  return value
}

private func transport(_ id: AudioObjectID) throws(GuardError) -> AudioTransport {
  AudioTransport(try read(id, kAudioDevicePropertyTransportType))
}

private func subDevices(_ id: AudioObjectID) throws -> [AudioObjectID] {
  let selector = kAudioAggregateDevicePropertyFullSubDeviceList
  var property = address(selector)
  var list: Unmanaged<CFArray>?
  var size = UInt32(MemoryLayout.size(ofValue: list))
  let status = AudioObjectGetPropertyData(id, &property, 0, nil, &size, &list)
  guard status == noErr else { throw GuardError.property(id, selector, status) }
  guard size == MemoryLayout.size(ofValue: list), let uids = list?.takeRetainedValue() as? [String]
  else { throw GuardError.unreadableAggregate(id) }
  return try uids.map { uid in
    var qualifier = uid as CFString
    let member = try withUnsafePointer(to: &qualifier) {
      try read(
        system, kAudioHardwarePropertyTranslateUIDToDevice,
        qualifier: $0, qualifierSize: UInt32(MemoryLayout<CFString>.size))
    }
    guard member != kAudioObjectUnknown else { throw GuardError.unreadableAggregate(id) }
    return member
  }
}

private func deviceName(_ id: AudioObjectID) -> String {
  var property = address(kAudioObjectPropertyName)
  var name: Unmanaged<CFString>?
  var size = UInt32(MemoryLayout.size(ofValue: name))
  let status = AudioObjectGetPropertyData(id, &property, 0, nil, &size, &name)
  return status == noErr ? (name?.takeRetainedValue() as String? ?? "unknown") : "unknown"
}

private enum Event: Sendable {
  case check
  case stop
}

private final class Listener {
  private let id: AudioObjectID
  private var property: AudioObjectPropertyAddress
  private let block: AudioObjectPropertyListenerBlock

  init(
    _ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
    changed: @escaping @Sendable () -> Void
  ) throws(GuardError) {
    self.id = id
    property = address(selector)
    block = { _, _ in changed() }
    let status = AudioObjectAddPropertyListenerBlock(id, &property, nil, block)
    guard status == noErr else { throw GuardError.property(id, selector, status) }
  }

  deinit {
    AudioObjectRemovePropertyListenerBlock(id, &property, nil, block)
  }
}

private func report(_ message: String, to file: FileHandle = .standardOutput) {
  file.write(Data("\(message)\n".utf8))
}

private func monitor() async throws {
  let (stream, events) = AsyncStream<Event>.makeStream()
  let activity = DeviceEvents()
  var listeners = try defaults.map { direction, selector in
    try Listener(system, selector) {
      // A replacement default can run before its device listener is installed.
      activity.routeChanged(.routeChanged(direction))
      events.yield(.check)
    }
  }
  defer { events.finish() }
  let initialRoutes = try defaults.map { try read(system, $0.1) }
  var roles: [AudioObjectID: [String]] = [:]
  for ((direction, _), id) in zip(defaults, initialRoutes) where id != kAudioObjectUnknown {
    roles[id, default: []].append(direction)
  }
  let devices = roles.map { id, role in
    Device(id: id, directions: role.joined(separator: " and "), name: deviceName(id))
  }
  listeners += try devices.map { device in
    try Listener(device.id, running) {
      // A transition may arrive after short playback has already stopped.
      activity.recordActivity(device.id)
      events.yield(.check)
    }
  }
  var observedAggregates: Set<AudioObjectID> = []
  for device in devices {
    // Arm aggregate membership notifications before accepting activity on those routes.
    _ = try AudioRoute(device.id, transport: transport) { id in
      if observedAggregates.insert(id).inserted {
        listeners.append(
          try Listener(id, kAudioAggregateDevicePropertyFullSubDeviceList) {
            activity.routeChanged(.aggregateChanged(id))
            events.yield(.check)
          })
      }
      return try subDevices(id)
    }
  }

  var reported: Set<AudioObjectID> = []
  func check() throws {
    try activity.checkRoutes()
    let pending = activity.takeActivity()
    for device in devices {
      let runningNow = try read(device.id, running) != 0
      guard runningNow || pending[device.id] != nil else { continue }
      let route = try AudioRoute(device.id, transport: transport, members: subDevices)
      if let hardware = route.hardware {
        throw Violation(reason: .active(device, hardware), time: pending[device.id] ?? .now)
      }
      if reported.insert(device.id).inserted {
        report("allowed: \(device.name) (\(route.transport.label))")
      }
    }
    for ((direction, selector), initial) in zip(defaults, initialRoutes) {
      if try read(system, selector) != initial { activity.routeChanged(.routeChanged(direction)) }
    }
    try activity.checkRoutes()
  }

  try check()
  if let output = initialRoutes.last, output != kAudioObjectUnknown {
    report("default output transport: \(try transport(output).label)")
  } else {
    report("default output transport: none")
  }
  report(devices.isEmpty ? "ready: no host devices" : "ready: monitoring default host devices")
  FileHandle.standardInput.readabilityHandler = { input in
    if input.availableData.isEmpty { events.yield(.stop) }
  }
  defer { FileHandle.standardInput.readabilityHandler = nil }
  let timer = Task {
    while !Task.isCancelled {
      try await Task.sleep(for: .milliseconds(20))
      events.yield(.check)
    }
  }
  defer { timer.cancel() }
  for await event in stream {
    switch event {
    case .check:
      try check()
    case .stop:
      try check()
      listeners.removeAll()
      try check()
      report("clean: host audio guard completed")
      return
    }
  }
}

do {
  try await monitor()
} catch {
  let timestamp = ISO8601DateFormatter()
  timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  let violation = error as? Violation
  let reason = violation?.reason.description ?? String(describing: error)
  report("\(timestamp.string(from: violation?.time ?? .now)) \(reason)", to: .standardError)
  exit(1)
}
