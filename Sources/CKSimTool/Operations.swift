#if os(macOS)
  import CKSimProtocol
  import Foundation
  import Synchronization

  /// Follows a run's journal, printing new entries, until Ctrl-C or the duration ends. It waits
  /// for a stopped app to start again, and follows a new session from its first entry.
  func watch(
    channel: URL, bundle: String, json: Bool, after: Int, duration: Duration?
  ) async throws {
    let interrupted = Interrupt()
    let end = duration.map { ContinuousClock.now + $0 }
    func finished() -> Bool {
      interrupted.happened || end.map { ContinuousClock.now >= $0 } == true
    }
    var journal = try Journal(channel: channel, bundle: bundle)
    var after = after
    var disconnected = false
    while true {
      let entries: [Journal.Entry]
      do {
        entries = try journal.read()
        disconnected = false
      } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        if !disconnected {
          FileHandle.standardError.write(
            Data("Runtime disconnected; waiting for its next session.\n".utf8))
          disconnected = true
        }
        if finished() { return }
        try await Task.sleep(for: .milliseconds(100))
        continue
      } catch let error as CKSimError where error.description.contains("session changed") {
        guard let next = try? Journal(channel: channel, bundle: bundle) else { continue }
        journal = next
        after = 0
        FileHandle.standardError.write(
          Data("Runtime session changed; following \(journal.session.runID)\n".utf8))
        continue
      }
      for entry in entries where entry.sequence > after {
        Tool.current.write(
          json ? String(decoding: entry.line, as: UTF8.self) : timelineLine(entry.json))
      }
      if finished() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  /// Launches the app with the package's runtime injected through `simctl`'s launch environment.
  func launch(simctl: Simctl, device: String, bundle: String, runtime: URL) throws -> [String: Any]
  {
    let package = runtime.standardizedFileURL.resolvingSymlinksInPath()
    let library = package.appending(path: "CKSimRuntime.dylib")
    guard FileManager.default.fileExists(atPath: library.path()) else {
      throw CKSimError("Missing CKSimRuntime.dylib in --runtime-dir.")
    }
    if let selected = try simctl.environment(device, "CKSIM_RUNTIME"), !selected.isEmpty,
      URL(filePath: selected).resolvingSymlinksInPath().path() != library.path()
    {
      throw CKSimError("Uninstall the other simulator runtime before launching this release.")
    }
    let inherited =
      try Tool.current.environment["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"]
      ?? simctl.environment(device, "DYLD_INSERT_LIBRARIES")
    for entry in (inherited ?? "").split(separator: ":").map(String.init) {
      let url = URL(filePath: entry)
      if ["CKSimRuntime.dylib", "CKSimLoader.dylib"].contains(url.lastPathComponent),
        url.deletingLastPathComponent().resolvingSymlinksInPath().path() != package.path()
      {
        throw CKSimError("Another simulator runtime is already injected; uninstall it first.")
      }
    }
    let environment = Tool.current.environment.merging([
      "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": [inherited, library.path(percentEncoded: false)]
        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ":"),
      "SIMCTL_CHILD_CKSIM_ENABLED": "1", "SIMCTL_CHILD_CKSIM_PROFILE": "ios-27.0",
    ]) { $1 }
    return [
      "launch": try simctl(
        "launch", "--terminate-running-process", device, bundle, environment: environment)
    ]
  }

  /// Serves the bridge and runs the Inspector app on a display simulator until Ctrl-C.
  func inspect(
    target: Target, timeout: Duration, app: URL, display requested: String?, allowShared: Bool
  ) async throws {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: app.path(), isDirectory: &isDirectory),
      isDirectory.boolValue, app.pathExtension == "app"
    else {
      throw CKSimError(
        "Build the simulator inspector first and pass inspect --app <CKSimInspector.app>.")
    }
    let simctl = target.simctl
    func say(_ message: String) { FileHandle.standardError.write(Data("\(message)\n".utf8)) }
    say("Inspector: locating target runtime.")
    let bridge = try InspectorBridge(target: target, timeout: timeout)
    say("Inspector: checking target runtime.")
    try await bridge.checkTarget()
    let interrupted = Interrupt()
    let server = try await InspectorServer(bridge: bridge)
    defer { server.stop() }
    var display: String?
    let owned = requested == nil
    defer {
      if owned, let display {
        _ = try? simctl("shutdown", display)
        _ = try? simctl("delete", display)
      }
    }
    if let requested {
      let device = try simctl.simulator(requested)
      if device == target.device && !allowShared {
        throw CKSimError(
          "Use a separate inspector simulator so the target app stays in the foreground.")
      }
      display = device
    } else {
      struct Devices: Decodable {
        struct Device: Decodable {
          let udid: String
          let deviceTypeIdentifier: String
        }
        let devices: [String: [Device]]
      }
      let list = try JSONDecoder().decode(
        Devices.self, from: Data(simctl("list", "devices", "-j").utf8))
      guard
        let (runtime, device) = list.devices.lazy.flatMap({ runtime, devices in
          devices.map { (runtime, $0) }
        }).first(where: { $0.1.udid == target.device })
      else { throw CKSimError("The target simulator isn't in the device list.") }
      let created = try simctl(
        "create", "CKSim Inspector \(UUID().uuidString.prefix(8).lowercased())",
        device.deviceTypeIdentifier, runtime)
      display = created
      try simctl("boot", created)
      try simctl("bootstatus", created, "-b", timeout: .seconds(300))
    }
    guard let display else { return }
    say("Inspector: installing app on display simulator.")
    try simctl("install", display, app.standardizedFileURL.path(percentEncoded: false))
    say("Inspector: launching app on display simulator.")
    let environment = ProcessInfo.processInfo.environment.merging([
      "SIMCTL_CHILD_CKSIM_INSPECTOR_URL": server.url,
      "SIMCTL_CHILD_CKSIM_INSPECTOR_TOKEN": server.token,
    ]) { $1 }
    try simctl(
      "launch", "--terminate-running-process", display, "dev.callkitsim.inspector",
      environment: environment, timeout: .seconds(display == target.device ? 20 : 180))
    let session = await bridge.session
    Tool.current.write(
      "Inspector on \(display), connected to \(target.bundle) (\(session.runID)). Ctrl-C to disconnect."
    )
    while !interrupted.happened { try await Task.sleep(for: .milliseconds(200)) }
  }

  /// Records Ctrl-C instead of exiting, so that a command can clean up first.
  final class Interrupt: Sendable {
    private let signalled = Mutex(false)
    private let source: any DispatchSourceSignal

    init() {
      signal(SIGINT, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: SIGINT)
      self.source = source
      source.setEventHandler { [weak self] in self?.signalled.withLock { $0 = true } }
      source.resume()
    }

    var happened: Bool { signalled.withLock { $0 } }
  }
#endif
