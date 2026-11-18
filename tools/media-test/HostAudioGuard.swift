import CoreAudio
import Foundation
import Synchronization

private enum GuardError: Error, CustomStringConvertible {
  case property(AudioObjectID, AudioObjectPropertySelector, OSStatus)
  case propertySize(AudioObjectID, AudioObjectPropertySelector, UInt32)
  case active(Device)
  case routeChanged(String)

  var description: String {
    switch self {
    case .property(let device, let selector, let status):
      "Core Audio property \(selector) on object \(device) failed (\(status))"
    case .propertySize(let device, let selector, let size):
      "Core Audio property \(selector) on object \(device) returned \(size) bytes"
    case .active(let device):
      "Host audio active on default \(device.directions) device \(device.name) (\(device.id))"
    case .routeChanged(let direction):
      "Default host audio \(direction) changed during monitoring"
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
  let time = Date.now
}

private final class ViolationLog: Sendable {
  private let first = Mutex<Violation?>(nil)

  func record(_ reason: GuardError) {
    let violation = Violation(reason: reason)
    first.withLock { if $0 == nil { $0 = violation } }
  }

  func check() throws(Violation) {
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

private func read(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws(GuardError)
  -> UInt32
{
  var property = address(selector)
  var value: UInt32 = 0
  var size = UInt32(MemoryLayout.size(ofValue: value))
  let status = AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value)
  guard status == noErr else { throw .property(id, selector, status) }
  guard size == MemoryLayout.size(ofValue: value) else { throw .propertySize(id, selector, size) }
  return value
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
  let violations = ViolationLog()
  var listeners = try defaults.map { direction, selector in
    try Listener(system, selector) {
      // A replacement default can run before its device listener is installed.
      violations.record(.routeChanged(direction))
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
      violations.record(.active(device))
      events.yield(.check)
    }
  }

  func check() throws {
    try violations.check()
    for device in devices {
      if try read(device.id, running) != 0 { violations.record(.active(device)) }
    }
    for ((direction, selector), initial) in zip(defaults, initialRoutes) {
      if try read(system, selector) != initial { violations.record(.routeChanged(direction)) }
    }
    try violations.check()
  }

  try check()
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
      try violations.check()
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
