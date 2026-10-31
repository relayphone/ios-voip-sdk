#if os(macOS)
  import CKSimProtocol
  import Foundation
  import Network
  import Synchronization

  /// What `cksim inspect` serves the Inspector app for one target: the target's journal, read
  /// incrementally, and the controls the Inspector sends, published to the target's mailbox. The
  /// target's session is pinned; a restarted target needs a new bridge.
  actor InspectorBridge {
    private let mailbox: Mailbox
    private var journal: Journal
    private var previous: (cursor: Int, batch: Data)?

    init(target: Target, timeout: Duration) throws {
      var target = target
      let channel = try target.channel()
      target.appContainer = try target.container()
      mailbox = Mailbox(target: target, timeout: timeout)
      journal = try Journal(channel: channel, bundle: target.bundle)
    }

    var session: RuntimeSession { journal.session }

    /// Checks that the target's runtime answers its status.
    func checkTarget() async throws {
      let response = try await mailbox.send(.status, expected: journal.session)
      guard response["success"] as? Bool == true else {
        throw CKSimError("Target runtime rejected inspector status.")
      }
      try journal.checkSession()
    }

    /// The journal entries after `cursor`, which must be where the last batch ended. Asking again
    /// for the last batch returns it again, so a failed response loses nothing.
    func events(after cursor: Int) throws -> Data {
      if let previous, previous.cursor == cursor {
        try journal.checkSession()
        return previous.batch
      }
      guard cursor == journal.sequence else {
        throw CKSimError("Timeline cursor changed; relaunch cksim inspect to reconnect.")
      }
      let entries = try journal.read()
      let events = entries.map(\.json)
      let batch = try JSONSerialization.data(withJSONObject: [
        "session": journal.published.json, "events": events, "cursor": journal.sequence,
      ])
      if !entries.isEmpty { previous = (cursor, batch) }
      return batch
    }

    /// Publishes one of the Inspector's controls and returns the runtime's response.
    func command(_ value: [String: Any]) async throws -> Data {
      let response = try await mailbox.send(
        Self.operation(value), expected: journal.session)
      return try JSONSerialization.data(withJSONObject: response)
    }

    /// The control an Inspector command names, after checking its parameters.
    static func operation(_ value: [String: Any]) throws -> ControlRequest.Operation {
      let keys = Set(value.keys)
      let operation = value["operation"] as? String
      if operation == "faults" {
        guard keys == ["operation", "incomingErrorCode"],
          let code = value["incomingErrorCode"] as? String, ["0", "4"].contains(code)
        else { throw CKSimError("Invalid incoming error fault.") }
        return .faults([.incomingErrorCode(Int(code) ?? 0)])
      }
      if operation == "incoming-filter" {
        guard keys == ["operation", "reason"],
          let reason = (value["reason"] as? String).flatMap(ControlRequest.FilterReason.init)
        else { throw CKSimError("Invalid incoming filter control.") }
        return .incomingFilter(reason)
      }
      let extra: [String: Set<String>] = [
        "hold": ["held"], "merge": ["groupWithCallUUID"], "unmerge": [],
        "end-held-and-accept": ["activeCallUUID", "heldCallUUID"],
      ]
      let legacy: Set = ["answer", "decline", "end", "hold-and-accept", "end-and-accept"]
      guard let operation, legacy.contains(operation) || extra[operation] != nil else {
        throw CKSimError("Unsupported inspector control.")
      }
      let required = Set(["operation", "callUUID"]).union(extra[operation] ?? [])
      var allowed = extra[operation] == nil ? required.union(["activeCallUUID"]) : required
      if keys.contains("applicationRequest") {
        guard ["hold", "merge", "unmerge"].contains(operation),
          value["applicationRequest"] as? String == "true"
        else { throw CKSimError("Invalid application request control.") }
        allowed.insert("applicationRequest")
      }
      guard required.isSubset(of: keys), keys.isSubset(of: allowed) else {
        throw CKSimError("Missing or unsupported inspector control parameters.")
      }
      var calls: [String: UUID] = [:]
      for field in ["callUUID", "activeCallUUID", "heldCallUUID", "groupWithCallUUID"]
      where keys.contains(field) {
        guard let text = value[field] as? String else {
          throw CKSimError("Inspector call identifiers must be UUID strings.")
        }
        guard let uuid = UUID(uuidString: text) else {
          throw CKSimError("badly formed hexadecimal UUID string")
        }
        calls[field] = uuid
      }
      let call = calls["callUUID"]!
      let origin: ControlRequest.Origin =
        value["applicationRequest"] as? String == "true" ? .application : .system
      func active() throws -> UUID {
        guard let active = calls["activeCallUUID"] else {
          throw CKSimError("Missing or unsupported inspector control parameters.")
        }
        return active
      }
      switch operation {
      case "answer": return .call(.answer(call))
      case "decline": return .call(.decline(call))
      case "end": return .call(.end(call))
      case "hold":
        guard let held = value["held"] as? String, ["true", "false"].contains(held) else {
          throw CKSimError("Inspector held must be true or false.")
        }
        return .call(.hold(call, held: held == "true", origin: origin))
      case "merge": return .call(.merge(call, with: calls["groupWithCallUUID"]!, origin: origin))
      case "unmerge": return .call(.unmerge(call, origin: origin))
      case "hold-and-accept": return .call(.holdAndAccept(call, active: try active()))
      case "end-and-accept": return .call(.endAndAccept(call, active: try active()))
      default:
        let (active, held) = (calls["activeCallUUID"]!, calls["heldCallUUID"]!)
        guard Set([call, active, held]).count == 3 else {
          throw CKSimError("Waiting, active and held calls must be distinct.")
        }
        return .call(.endHeldAndAccept(call, active: active, held: held))
      }
    }
  }

  /// The bridge's HTTP server on the host's loopback interface. Every request needs the bearer
  /// token, which `cksim inspect` passes to the Inspector app in its launch environment.
  final class InspectorServer: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cksim.inspector")
    let token: String

    /// Starts serving the bridge and returns once the server listens.
    init(bridge: InspectorBridge) async throws {
      var bytes = [UInt8](repeating: 0, count: 32)
      guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw CKSimError("Cannot create the Inspector's token.")
      }
      token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
      let parameters = NWParameters.tcp
      parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
      listener = try NWListener(using: parameters)
      let token = token
      listener.newConnectionHandler = { [queue] connection in
        connection.start(queue: queue)
        Task { await Self.serve(connection, bridge: bridge, token: token) }
      }
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let resumed = Mutex(false)
        listener.stateUpdateHandler = { state in
          let result: Result<Void, any Error>? =
            switch state {
            case .ready: .success(())
            case .failed(let error): .failure(error)
            case .cancelled: .failure(CKSimError("The Inspector's server stopped."))
            default: nil
            }
          guard let result,
            resumed.withLock({ value in
              defer { value = true }
              return !value
            })
          else { return }
          continuation.resume(with: result)
        }
        listener.start(queue: queue)
      }
    }

    /// The server's URL.
    var url: String { "http://127.0.0.1:\(listener.port?.rawValue ?? 0)" }

    func stop() { listener.cancel() }

    private static func serve(
      _ connection: NWConnection, bridge: InspectorBridge, token: String
    ) async {
      defer { connection.cancel() }
      guard let request = await HTTPRequest(reading: connection) else { return }
      var status = 200
      var body: Data
      if request.headers["authorization"] != "Bearer " + token {
        status = 401
        body = Data(#"{"error":"Unauthorized"}"#.utf8)
      } else {
        do {
          switch (request.method, request.path) {
          case ("GET", "/events"):
            body = try await bridge.events(after: Int(request.query["after"] ?? "0") ?? -1)
          case ("POST", "/command"):
            guard (1...4096).contains(request.body.count),
              let value = try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
            else { throw CKSimError("Invalid command size.") }
            body = try await bridge.command(value)
          default:
            status = 404
            body = Data(#"{"error":"Not found"}"#.utf8)
          }
        } catch {
          status = 409
          body = (try? JSONSerialization.data(withJSONObject: ["error": "\(error)"])) ?? Data()
        }
      }
      let reason =
        [200: "OK", 401: "Unauthorized", 404: "Not Found", 409: "Conflict"][status] ?? ""
      var response = Data(
        ("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\n"
          + "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n")
          .utf8)
      response.append(body)
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        connection.send(
          content: response, completion: .contentProcessed { _ in continuation.resume() })
      }
    }
  }

  /// One HTTP/1.1 request, read until its headers and its `Content-Length` body arrive.
  struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    init?(reading connection: NWConnection) async {
      var data = Data()
      let separator = Data("\r\n\r\n".utf8)
      while true {
        if let end = data.range(of: separator) {
          let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
          var lines = head.components(separatedBy: "\r\n")
          let start = lines.removeFirst().split(separator: " ")
          guard start.count == 3 else { return nil }
          var headers: [String: String] = [:]
          for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
              .trimmingCharacters(in: .whitespaces)
          }
          let length = Int(headers["content-length"] ?? "0") ?? -1
          guard (0...65_536).contains(length) else { return nil }
          while data.count - end.upperBound < length {
            guard let more = await Self.receive(connection) else { return nil }
            data.append(more)
          }
          let target = URLComponents(string: String(start[1]))
          method = String(start[0])
          path = target?.path ?? ""
          query = Dictionary(
            (target?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
          self.headers = headers
          body = data[end.upperBound..<end.upperBound + length]
          return
        }
        guard data.count < 65_536, let more = await Self.receive(connection) else { return nil }
        data.append(more)
      }
    }

    private static func receive(_ connection: NWConnection) async -> Data? {
      await withCheckedContinuation { continuation in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
          data, _, complete, error in
          continuation.resume(returning: error == nil && !(data?.isEmpty ?? true) ? data : nil)
          _ = complete
        }
      }
    }
  }
#endif
