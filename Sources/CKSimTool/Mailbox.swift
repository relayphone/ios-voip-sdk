#if os(macOS)
  import CKSimProtocol
  import Foundation

  /// A running app with the runtime, in one simulator.
  struct Target {
    let simctl: Simctl
    let device: String
    let bundle: String
    /// A data container found earlier, which saves a query to the simulator.
    var appContainer: URL?

    /// The app's data container.
    func container() throws -> URL {
      guard let appContainer else {
        return URL(filePath: try simctl("get_app_container", device, bundle, "data"))
      }
      let container = appContainer.standardizedFileURL.resolvingSymlinksInPath()
      var isDirectory: ObjCBool = false
      let parts = container.pathComponents
      let expected = [device, "data", "Containers", "Data", "Application"].map { $0.lowercased() }
      guard FileManager.default.fileExists(atPath: container.path(), isDirectory: &isDirectory),
        isDirectory.boolValue, parts.count >= 6,
        parts.suffix(6).dropLast().map({ $0.lowercased() }) == expected,
        UUID(uuidString: container.lastPathComponent) != nil
      else {
        throw CKSimError(
          "Cached app container must be an existing data container for the selected simulator.")
      }
      return container
    }

    /// `Documents/.callkit-simulator`, where the runtime publishes its session and mailbox.
    func channel() throws -> URL {
      try container().appending(path: "Documents/.callkit-simulator")
    }
  }

  /// The runtime session that the target app published, as its raw JSON for receipts and as the
  /// typed session.
  struct PublishedSession {
    let session: RuntimeSession
    let json: [String: Any]
    let data: Data

    /// Reads and checks the session in a channel.
    init(channel: URL, bundle: String) throws {
      data = try Data(contentsOf: channel.appending(path: "session.json"))
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      guard let object, let session = try? JSONDecoder().decode(RuntimeSession.self, from: data),
        session.bundleID == bundle
      else {
        if let transport = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?[
          "controlTransport"] as? String, transport != "directory-watch-v1"
        {
          throw CKSimError(
            "Unsupported runtime control transport; rebuild the runtime and relaunch the app.")
        }
        throw CKSimError("Invalid runtime session; launch the app with this runtime first.")
      }
      self.session = session
      json = object
    }
  }

  /// Sends one control through the runtime's mailbox and waits for its response.
  struct Mailbox {
    let target: Target
    /// How long to wait for the runtime's response.
    let timeout: Duration
    /// A new file in which to keep the session, request and response.
    var receipt: URL?

    /// Sends the control and returns the runtime's response as JSON.
    ///
    /// - Parameter expected: The session a bridge connected to; a changed session refuses the
    ///   control.
    func send(_ operation: ControlRequest.Operation, expected: RuntimeSession? = nil) async throws
      -> [String: Any]
    {
      if let receipt, exists(receipt) {
        throw CKSimError("Command receipt already exists; inspect before retrying.")
      }
      let channel = try target.channel()
      let published = try PublishedSession(channel: channel, bundle: target.bundle)
      if let expected, published.session != expected {
        throw CKSimError("Runtime session changed; reconnect before sending controls.")
      }
      let session = published.session
      let identity = try RuntimeIdentity(
        bundleID: session.bundleID, runID: session.runID, pid: session.pid)
      let request = try ControlRequest(id: UUID(), target: identity, operation: operation)
      let bytes = try JSONEncoder().encode(request)
      let mailbox = channel.appending(path: session.runID)
      let name = request.id.uuidString
      let staged = mailbox.appending(path: "requests/\(name).tmp")
      guard
        FileManager.default.createFile(
          atPath: staged.path(), contents: bytes, attributes: [.posixPermissions: 0o600]),
        rename(staged.path(), mailbox.appending(path: "requests/\(name).json").path()) == 0
      else { throw CKSimError("Cannot publish command \(name).") }
      let responseFile = mailbox.appending(path: "responses/\(name).json")
      let deadline = ContinuousClock.now + timeout
      while ContinuousClock.now < deadline {
        if let data = try? Data(contentsOf: responseFile) {
          guard let response = try? JSONDecoder().decode(ControlResponse.self, from: data),
            response.id == request.id, response.target == identity,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
          else { throw CKSimError("Runtime response identity mismatch.") }
          if let receipt {
            try writeNew(
              receipt,
              json: [
                "schemaVersion": 1, "session": published.json,
                "request": try JSONSerialization.jsonObject(with: bytes), "response": object,
              ])
          }
          return object
        }
        try await Task.sleep(for: .milliseconds(50))
      }
      throw CKSimError(
        "Command \(name) timed out; outcome is unknown. Query status/events before retrying.")
    }
  }

  /// Whether anything, even a dangling symbolic link, is at the path.
  func exists(_ url: URL) -> Bool {
    var status = stat()
    return lstat(url.path(), &status) == 0
  }

  /// Writes pretty JSON to a file that mustn't exist yet, readable only by its owner.
  func writeNew(_ url: URL, json: Any) throws {
    var data = try JSONSerialization.data(
      withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(10)
    let descriptor = open(url.path(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw CKSimError("\(String(cString: strerror(errno))): \(url.path(percentEncoded: false))")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    try handle.write(contentsOf: data)
    try handle.close()
  }
#endif
