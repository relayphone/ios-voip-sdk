#if os(macOS)
  import Foundation
  import CKSimProtocol

  /// `cksim push --launch`: stages a VoIP push for a stopped app that activates the runtime
  /// itself, then becomes the app's launcher. The runtime delivers the push after it installs its
  /// PushKit hooks; nothing is injected into the app.
  struct PushLaunch {
    let target: Target
    let runID: String
    let mustReport: Bool
    let payloadFile: URL
    let receipt: URL
    var delivery: PushDeliveryFaults = .none
    private let requestID = UUID()

    private struct DroppedReceipt: Encodable {
      let schemaVersion = 1
      let simulatorID: String
      let bundleID: String
      let runID: String
      let pushID: UUID
      let dropped = true
      let runtimeInjectionRequested = false
    }

    /// Stages the push after checking, from the simulator's service table, that the app isn't
    /// running, and returns the launcher's arguments and environment.
    func stage(container: URL, serviceTable: Data, payload: PushPayload? = nil) throws -> (
      arguments: [String], environment: [String: String]
    ) {
      guard !exists(receipt) else {
        throw CKSimError("Launch receipt already exists; inspect before staging.")
      }
      let services = String(decoding: serviceTable, as: UTF8.self)
      let rows = services.split(whereSeparator: \.isNewline).map {
        $0.split(whereSeparator: \.isWhitespace).map(String.init)
      }.filter { !$0.isEmpty }
      func matches(_ text: String, signed: Bool) -> Bool {
        if text == "-" { return true }
        let digits = signed && text.hasPrefix("-") ? text.dropFirst() : Substring(text)
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
          && (signed || digits.first != "0")
      }
      guard rows.count >= 2, rows[0] == ["PID", "Status", "Label"],
        rows.dropFirst().allSatisfy({
          $0.count == 3 && matches($0[0], signed: false) && matches($0[1], signed: true)
        })
      else { throw CKSimError("Invalid launchctl service table; cannot establish stopped app.") }
      if rows.dropFirst().contains(where: {
        (Int($0[0]) ?? 0) > 0 && $0[2].hasPrefix("UIKitApplication:\(target.bundle)[")
      }) {
        throw CKSimError("Push launch requires a stopped app; inspect/stop it before staging.")
      }
      let root = container.appending(path: "Documents/.callkit-simulator")
      try? FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      var status = stat()
      guard lstat(root.path(), &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
        status.st_mode & 0o7777 == 0o700, status.st_uid == getuid()
      else { throw CKSimError("Unsafe push launch directory.") }
      guard !exists(root.appending(path: "push-launch.consuming")) else {
        throw CKSimError("A push launch claim already exists; inspect before retrying.")
      }
      let payload = try payload ?? readPayload()
      let id = requestID
      let created = Int64(Date().timeIntervalSince1970 * 1000)
      let envelope = try PushLaunchEnvelope(
        id: id, runID: runID, bundleID: target.bundle,
        createdAtMS: created, expiresAtMS: created + 30_000, mustReport: mustReport,
        payload: payload, delivery: delivery)
      guard !exists(root.appending(path: runID)),
        !exists(root.appending(path: "process/\(runID)"))
      else {
        throw CKSimError(
          "Push launch requires a fresh run identifier; prior journal segments exist.")
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      var data = try encoder.encode(envelope)
      data.append(10)
      let file = root.appending(path: "push-launch.json")
      let temporary = root.appending(path: ".push-launch-\(UUID().uuidString)")
      defer { unlink(temporary.path()) }
      let descriptor = open(temporary.path(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
      guard descriptor >= 0 else { throw CKSimError(String(cString: strerror(errno))) }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
      // An exclusive link never replaces a pending push.
      guard link(temporary.path(), file.path()) == 0 else {
        throw CKSimError("\(String(cString: strerror(errno))): \(file.path(percentEncoded: false))")
      }
      var staged = stat()
      _ = stat(file.path(), &staged)
      try writeNew(
        receipt,
        json: [
          "schemaVersion": 1, "simulatorID": target.device, "bundleID": target.bundle,
          "runID": runID, "pushID": id.uuidString,
          "envelope": try JSONSerialization.jsonObject(with: data), "envelopeSHA256": sha256(data),
          "mode": Int(staged.st_mode & 0o7777), "appServiceAbsent": true,
          "serviceQuery": services, "serviceQuerySHA256": sha256(serviceTable),
          "runtimeInjectionRequested": false,
        ])
      // Keep every inherited simulator override; inject nothing.
      return (
        ["/usr/bin/xcrun", "simctl", "launch", "--console", target.device, target.bundle],
        ProcessInfo.processInfo.environment.merging(["SIMCTL_CHILD_CKSIM_RUN_ID": runID]) { $1 }
      )
    }

    /// Stages the push and durably records intent before returning the launch command.
    func prepare(clock: some Clock<Duration> = ContinuousClock()) async throws -> (
      arguments: [String], environment: [String: String]
    )? {
      let accepted = clock.now
      guard !exists(receipt) else {
        throw CKSimError("Launch receipt already exists; inspect before staging.")
      }
      // Freeze and validate the whole payload before waiting or writing any intent.
      let payload = try readPayload()
      let id = requestID
      _ = try PushLaunchEnvelope(
        id: id, runID: runID, bundleID: target.bundle, createdAtMS: 0,
        expiresAtMS: 30_000, mustReport: mustReport, payload: payload, delivery: delivery)
      guard delivery.duplicate == 0 else {
        throw CKSimError("Cold-launch duplicates require host exit tracking.")
      }
      guard let simulatorID = UUID(uuidString: target.device) else {
        throw CKSimError("Process journal requires a resolved simulator UUID.")
      }
      try Task.checkCancellation()
      try await clock.sleep(
        until: accepted.advanced(by: .milliseconds(delivery.delayMS)), tolerance: nil)
      try Task.checkCancellation()
      let container = URL(
        filePath: try target.simctl("get_app_container", target.device, target.bundle, "data"))
      try Task.checkCancellation()
      if delivery.drop {
        let channel = container.appending(path: "Documents/.callkit-simulator")
        guard !exists(channel.appending(path: runID)),
          !exists(channel.appending(path: "process/\(runID)"))
        else { throw CKSimError("Push launch requires a fresh run identifier.") }
        let journal = try ProcessLifecycle(
          channel: channel,
          identity: ProcessLifecycleIdentity(
            simulatorID: simulatorID, bundleID: target.bundle, runID: runID))
        try await journal.record(.dropped, requestID: id, pushID: id)
        try writeNew(
          receipt,
          json: JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
              DroppedReceipt(
                simulatorID: target.device, bundleID: target.bundle, runID: runID, pushID: id))))
        return nil
      }
      let query: ProcessOutput
      do {
        query = try target.simctl.run(
          ["spawn", target.device, "launchctl", "list"],
          ProcessInfo.processInfo.environment.merging(["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": ""]) {
            $1
          }, Simctl.limit)
      } catch is ProcessTimeout {
        throw CKSimError("Stopped-app query timed out; inspect before staging.")
      }
      guard query.status == 0, query.standardError.isEmpty else {
        throw CKSimError(
          "Stopped-app query failed or returned diagnostics: \(query.diagnostic)")
      }
      try Task.checkCancellation()
      let (arguments, environment) = try stage(
        container: container, serviceTable: query.standardOutput, payload: payload)
      let journal = try ProcessLifecycle(
        channel: container.appending(path: "Documents/.callkit-simulator"),
        identity: ProcessLifecycleIdentity(
          simulatorID: simulatorID, bundleID: target.bundle, runID: runID))
      try await journal.record(.launchRequested, requestID: requestID)
      return (arguments, environment)
    }

    private func readPayload() throws -> PushPayload {
      try JSONDecoder().decode(PushPayload.self, from: Data(contentsOf: payloadFile))
    }

    /// Stages the push, then replaces this process with the app's console launcher.
    func run() async throws {
      guard let (arguments, environment) = try await prepare() else { return }
      try Task.checkCancellation()
      execute(arguments, environment: environment)
    }
  }

  /// Replaces this process with the program.
  func execute(_ arguments: [String], environment: [String: String]) -> Never {
    let argv = arguments.map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    execve(arguments[0], argv, envp)
    FileHandle.standardError.write(Data("cksim: \(String(cString: strerror(errno)))\n".utf8))
    exit(1)
  }
#endif
