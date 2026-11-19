import CoreAudio
import Darwin
import Foundation
import Synchronization

struct ProcessAudioActivity {
  let pid: pid_t
  let executable: String
  let direction: AudioDirection
  let device: AudioObjectID?
  let uid: String?
  let isVirtual: Bool
  let belongsToSimulator: Bool
}

struct LeaseAudioRoutes {
  let input: String
  let output: String

  func violation(in activity: [ProcessAudioActivity]) -> ProcessAudioActivity? {
    activity.first { row in
      row.belongsToSimulator
        && (!row.isVirtual || row.uid != (row.direction == .input ? input : output))
    }
  }
}

private struct ProcessIdentity: Hashable {
  let pid: pid_t
  let seconds: Int
  let microseconds: Int32
}

private struct ProcessInfo {
  let identity: ProcessIdentity
  let parent: pid_t

  init?(_ pid: pid_t) throws {
    guard pid > 0 else { return nil }
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&query, u_int(query.count), &info, &size, nil, 0) == 0
    else { throw LeaseMonitorError.unreadableProcess(pid, errno) }
    guard size > 0 else { return nil }
    identity = ProcessIdentity(
      pid: pid, seconds: info.kp_proc.p_starttime.tv_sec,
      microseconds: info.kp_proc.p_starttime.tv_usec)
    parent = info.kp_eproc.e_ppid
  }
}

private func executablePath(_ pid: pid_t) -> String? {
  var bytes = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
  guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
  return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
}

private struct SimulatorProcesses {
  let udid: UUID
  let root: ProcessIdentity
  var attributed: Set<ProcessIdentity> = []

  init(udid: UUID, launchd: pid_t) throws {
    guard launchd > 1, let process = try ProcessInfo(launchd),
      executablePath(launchd).map({ URL(fileURLWithPath: $0).lastPathComponent }) == "launchd_sim"
    else { throw LeaseMonitorError.invalidLaunchd }
    self.udid = udid
    root = process.identity
  }

  mutating func track(_ pid: pid_t) throws {
    if let process = try ProcessInfo(pid) { attributed.insert(process.identity) }
  }

  mutating func contains(_ pid: pid_t, executable: String?) throws -> Bool {
    guard let process = try ProcessInfo(pid) else { return false }
    if attributed.contains(process.identity) { return true }
    // A simulator app can be reparented. Its installed executable still belongs to this UDID.
    let installedApp =
      executable?.split(separator: "/").contains {
        UUID(uuidString: String($0)) == udid
      } == true
    var ancestor: ProcessInfo? = process
    var visited: Set<pid_t> = []
    while let current = ancestor, visited.insert(current.identity.pid).inserted {
      if installedApp || current.identity == root || attributed.contains(current.identity) {
        attributed.insert(process.identity)
        return true
      }
      ancestor = current.parent > 1 ? try ProcessInfo(current.parent) : nil
    }
    return false
  }

  func pidForAudioObject(_ object: AudioObjectID, system: AudioObjectID) throws -> pid_t? {
    // Some HAL objects can temporarily be enumerated before their PID property is readable.
    // Resolve the lease's processes in the opposite direction before ignoring such an object.
    var candidates = try ([root] + attributed).compactMap { identity in
      try ProcessInfo(identity.pid)?.identity == identity ? identity.pid : nil
    }
    var visited: Set<pid_t> = []
    while var pid = candidates.popLast() {
      guard visited.insert(pid).inserted else { continue }
      let translated = try withUnsafePointer(to: &pid) {
        try read(
          system, kAudioHardwarePropertyTranslatePIDToProcessObject,
          qualifier: $0, qualifierSize: UInt32(MemoryLayout<pid_t>.size))
      }
      if translated == object { return pid }
      let capacity = proc_listchildpids(pid, nil, 0)
      guard capacity >= 0 else { throw LeaseMonitorError.unreadableProcess(pid, errno) }
      guard capacity > 0 else { continue }
      var children = [pid_t](repeating: 0, count: Int(capacity) * 2)
      let count = proc_listchildpids(
        pid, &children, Int32(children.count * MemoryLayout<pid_t>.stride))
      guard count >= 0, count < children.count
      else { throw LeaseMonitorError.unreadableProcess(pid, errno) }
      candidates.append(contentsOf: children.prefix(Int(count)).filter { $0 > 1 })
    }
    return nil
  }
}

private enum LeaseMonitorError: Error, CustomStringConvertible {
  case invalidLaunchd
  case invalidControl
  case unreadableProcess(pid_t, Int32)
  case audio(ProcessAudioActivity, [ProcessAudioActivity])

  var description: String {
    switch self {
    case .invalidLaunchd:
      return "Could not identify the isolated simulator's launchd process"
    case .invalidControl:
      return "Invalid isolated simulator guard command"
    case .unreadableProcess(let pid, let code):
      return "Could not attribute active Core Audio process PID \(pid) (\(code))"
    case .audio(let offending, let activity):
      let device = offending.uid.map { String(reflecting: $0) } ?? "unknown UID"
      let id = offending.device.map(String.init) ?? "unavailable"
      let related = activity.filter {
        offending.device == nil
          ? $0.pid == offending.pid && $0.direction == offending.direction
          : $0.device == offending.device
      }
      let processes = related.map {
        "PID \($0.pid), executable \(String(reflecting: $0.executable)), direction \($0.direction.rawValue)"
      }
      return
        ([
          "Isolated simulator process used an unapproved \(offending.direction.rawValue) device \(device) (\(id))",
          "Offending process PID \(offending.pid)",
        ] + processes).joined(separator: "\n")
    }
  }
}

private func objectIDs(
  _ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) throws(GuardError) -> [AudioObjectID] {
  var property = address(selector, scope: scope)
  var size: UInt32 = 0
  let sizing = AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size)
  guard sizing == noErr else { throw .property(id, selector, sizing) }
  let stride = UInt32(MemoryLayout<AudioObjectID>.stride)
  guard size.isMultiple(of: stride) else { throw .propertySize(id, selector, size) }
  guard size > 0 else { return [] }
  var ids = [AudioObjectID](repeating: 0, count: Int(size / stride))
  let status = AudioObjectGetPropertyData(id, &property, 0, nil, &size, &ids)
  guard status == noErr else { throw .property(id, selector, status) }
  guard size.isMultiple(of: stride), size / stride <= ids.count else {
    throw .propertySize(id, selector, size)
  }
  return Array(ids.prefix(Int(size / stride)))
}

func disappearedProcess(
  _ error: GuardError, object: AudioObjectID, refresh: () throws -> [AudioObjectID]
) throws -> Bool {
  guard case .property(_, _, let status) = error,
    status == kAudioHardwareBadObjectError || status == kAudioHardwareUnknownPropertyError
  else { return false }
  return try !refresh().contains(object)
}

func audioProcessPID(
  readPID: () throws(GuardError) -> UInt32, reverseLookup: () throws -> pid_t?
) throws -> pid_t? {
  do { return pid_t(bitPattern: try readPID()) } catch {
    guard case .property(_, _, let status) = error,
      status == kAudioHardwareBadObjectError || status == kAudioHardwareUnknownPropertyError
    else { throw error }
    return try reverseLookup()
  }
}

private func currentActivity(
  _ processes: inout SimulatorProcesses, includeForeign: Bool = false
) throws -> [ProcessAudioActivity] {
  let system = AudioObjectID(kAudioObjectSystemObject)
  let list = kAudioHardwarePropertyProcessObjectList
  var activity: [ProcessAudioActivity] = []
  for object in try objectIDs(system, list) {
    do {
      guard
        let pid = try audioProcessPID(
          readPID: { () throws(GuardError) in try read(object, kAudioProcessPropertyPID) },
          reverseLookup: { try processes.pidForAudioObject(object, system: system) })
      else { continue }
      let path = executablePath(pid)
      let belongs = try processes.contains(pid, executable: path)
      guard belongs || includeForeign else { continue }
      let input = try read(object, kAudioProcessPropertyIsRunningInput) != 0
      let output = try read(object, kAudioProcessPropertyIsRunningOutput) != 0
      guard input || output else { continue }
      let executable = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unavailable"
      func append(_ direction: AudioDirection, _ scope: AudioObjectPropertyScope) {
        let ids = (try? objectIDs(object, kAudioProcessPropertyDevices, scope: scope)) ?? []
        let devices: [AudioObjectID?] = ids.isEmpty ? [nil] : ids.map(Optional.some)
        for device in devices {
          let uid = device.flatMap { try? identityString($0, kAudioDevicePropertyDeviceUID) }
          let virtual = device.flatMap { try? transport($0) } == .virtual
          activity.append(
            ProcessAudioActivity(
              pid: pid, executable: executable, direction: direction, device: device,
              uid: uid, isVirtual: virtual, belongsToSimulator: belongs))
        }
      }
      if input { append(.input, kAudioObjectPropertyScopeInput) }
      if output { append(.output, kAudioObjectPropertyScopeOutput) }
    } catch  where includeForeign {
      continue
    } catch let error as GuardError {
      // A process can disconnect between the list and its property reads.
      guard try disappearedProcess(error, object: object, refresh: { try objectIDs(system, list) })
      else { throw error }
    }
  }
  return activity
}

func monitorLeaseAudio(udid: UUID, launchd: pid_t, routes: LeaseAudioRoutes) async throws {
  var processes = try SimulatorProcesses(udid: udid, launchd: launchd)
  struct Control: Sendable {
    var pending = Data()
    var stopped = false
  }
  let control = Mutex(Control())
  var releasing = false
  FileHandle.standardInput.readabilityHandler = { input in
    let data = input.availableData
    control.withLock {
      if data.isEmpty { $0.stopped = true } else { $0.pending.append(data) }
    }
  }
  defer { FileHandle.standardInput.readabilityHandler = nil }

  func check() throws -> Bool {
    let (bytes, stopped) = control.withLock { state in
      guard let newline = state.pending.lastIndex(of: 10) else { return (Data(), state.stopped) }
      let lines = state.pending[...newline]
      state.pending.removeSubrange(...newline)
      return (lines, state.stopped)
    }
    for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") {
      if line == "release" {
        releasing = true
      } else if let pid = pid_t(line), pid > 1 {
        try processes.track(pid)
      } else {
        throw LeaseMonitorError.invalidControl
      }
    }
    if !releasing, try ProcessInfo(launchd)?.identity != processes.root {
      throw LeaseMonitorError.invalidLaunchd
    }
    let activity = try currentActivity(&processes)
    if let violation = routes.violation(in: activity) {
      let otherActivity = (try? currentActivity(&processes, includeForeign: true)) ?? []
      throw LeaseMonitorError.audio(
        violation, activity + otherActivity.filter { !$0.belongsToSimulator })
    }
    return stopped
  }
  _ = try check()
  report("ready: monitoring isolated simulator processes")
  while try !check() {
    try await Task.sleep(for: .milliseconds(20))
  }
  report("clean: host audio guard completed")
}
