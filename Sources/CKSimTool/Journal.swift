#if os(macOS)
  import CKSimProtocol
  import Foundation

  /// A reader of one run's journal, `<runID>/events.jsonl`, that reads only what was added since
  /// it last read and checks every entry's version, identity and sequence.
  struct Journal {
    /// One entry: its JSON and its line as the runtime wrote it.
    struct Entry {
      let json: [String: Any]
      let line: Data
      var sequence: Int { json["sequence"] as? Int ?? 0 }
    }

    private static let limit = 1024 * 1024

    let channel: URL
    let published: PublishedSession
    private let file: URL
    private var offset: UInt64 = 0
    private var partial = Data()
    /// The sequence of the last entry read.
    private(set) var sequence = 0

    var session: RuntimeSession { published.session }

    /// Opens the journal of the session that the channel publishes now.
    init(channel: URL, bundle: String) throws {
      self.channel = channel
      published = try PublishedSession(channel: channel, bundle: bundle)
      file = channel.appending(path: "\(published.session.runID)/events.jsonl")
    }

    /// Checks that the channel still publishes the same session.
    func checkSession() throws {
      guard try Data(contentsOf: channel.appending(path: "session.json")) == published.data else {
        throw CKSimError("Runtime session changed; reconnect to the new run.")
      }
    }

    /// Reads the entries added since the last read.
    mutating func read() throws -> [Entry] {
      try checkSession()
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }
      let size = try handle.seekToEnd()
      guard size >= offset else {
        throw CKSimError("Runtime journal was truncated; reconnect to the run.")
      }
      try handle.seek(toOffset: offset)
      let data = try handle.read(upToCount: Self.limit) ?? Data()
      offset += UInt64(data.count)
      var lines = (partial + data).split(separator: 10, omittingEmptySubsequences: false)
      partial = Data(lines.removeLast())
      guard partial.count <= Self.limit else { throw CKSimError("Runtime event exceeds 1 MiB.") }
      return try lines.map { line in
        let data = Data(line)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          json["schemaVersion"] as? Int == 1, json["runID"] as? String == session.runID,
          json["pid"] as? Int == session.pid, json["bundleID"] as? String == session.bundleID,
          isInteger(json["sequence"]), json["sequence"] as? Int == sequence + 1,
          json["event"] is String, isInteger(json["t_ms"]), isInteger(json["wallTimeMS"])
        else { throw CKSimError("Unsupported or inconsistent runtime event channel.") }
        sequence += 1
        return Entry(json: json, line: data)
      }
    }
  }

  /// Whether a JSON value is an integer, not a Boolean or a fraction.
  func isInteger(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return false
    }
    return String(cString: number.objCType) != "d" && String(cString: number.objCType) != "f"
  }

  /// One line of `cksim watch`'s timeline for a journal entry.
  func timelineLine(_ row: [String: Any]) -> String {
    var detail: [String] = []
    for key in ["kind", "origin", "callerName", "callUUID", "uuid"] {
      guard let value = row[key], !(value is NSNull) else { continue }
      let text = "\(value)"
      if text.isEmpty || (value as? NSNumber).map({ $0 == 0 }) == true { continue }
      detail.append(String(text.unicodeScalars.map { isPrintable($0) ? Character($0) : "?" }))
    }
    if let deadline = row["deadlineSeconds"] as? Double {
      detail.append(
        "budget \(String(format: "%g", deadline))s (\(row["apiKind"] as? String ?? ""))")
    }
    let event = row["event"] as? String ?? ""
    if event == "action.settled" {
      let latency = row["latencyMS"] as? Double ?? 0
      detail.append(
        (row["fulfilled"] as? Bool == true ? "fulfilled" : "failed")
          + " in \(String(format: "%.1f", latency))ms")
    }
    if event == "call.changed" {
      let state: String =
        if row["ended"] as? Bool == true { "ended" } else if row["held"] as? Bool == true {
          "held"
        } else if row["connected"] as? Bool == true { "connected" } else { "ringing" }
      detail.append(state)
    }
    let sequence = String(row["sequence"] as? Int ?? 0)
    let time = String(format: "%9.3f", Double(row["t_ms"] as? Int ?? 0) / 1000)
    let name = event.padding(toLength: max(25, event.count), withPad: " ", startingAt: 0)
    return String(repeating: " ", count: max(0, 6 - sequence.count)) + sequence + " " + time
      + "s  " + name + " " + detail.joined(separator: " · ")
  }

  /// Whether the scalar prints as itself in the timeline; others print as `?`.
  private func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator,
      .paragraphSeparator:
      false
    case .spaceSeparator: scalar == " "
    default: true
    }
  }
#endif
