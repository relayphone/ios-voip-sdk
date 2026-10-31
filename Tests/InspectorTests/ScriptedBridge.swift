import Foundation

@testable import CKSimInspector

/// A bridge whose journal the test writes, and which answers each command with a response the
/// test builds. It records the commands the Inspector sends.
@MainActor
final class ScriptedBridge: InspectorBridge {
  static let session: [String: Any] = [
    "schemaVersion": 1, "bundleID": "fixture", "runID": "scripted", "pid": 123,
    "profile": "ios-27.0", "controlTransport": "directory-watch-v1",
  ]

  private var rows: [[String: Any]] = []
  private(set) var commands: [[String: String]] = []
  /// The result or failure fields of the response to the command at this one-based index.
  var respond: (_ command: [String: String], _ index: Int) -> [String: Any] = { _, _ in [:] }

  /// The response identifier for the command at this one-based index.
  static func responseID(_ index: Int) -> String {
    String(format: "10000000-0000-4000-8000-%012X", index)
  }

  /// Appends a journal entry for the scripted run.
  func append(_ event: String, _ fields: [String: Any] = [:]) {
    var row: [String: Any] = [
      "schemaVersion": 1, "bundleID": "fixture", "runID": "scripted", "pid": 123,
      "sequence": rows.count + 1, "t_ms": (rows.count + 1) * 10, "event": event,
    ]
    row.merge(fields) { _, new in new }
    rows.append(row)
  }

  func events(after cursor: Int) async throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "session": Self.session, "events": Array(rows.dropFirst(cursor)), "cursor": rows.count,
    ])
  }

  func command(_ body: [String: String]) async throws -> Data {
    commands.append(body)
    let index = commands.count
    append("test.commandAccepted", ["requestID": Self.responseID(index)])
    var response: [String: Any] = [
      "id": Self.responseID(index), "runID": "scripted", "pid": 123, "bundleID": "fixture",
      "success": true,
    ]
    response.merge(respond(body, index)) { _, new in new }
    return try JSONSerialization.data(withJSONObject: response)
  }
}

/// Follows the bridge with a new model until the test ends.
@MainActor
func following(_ bridge: ScriptedBridge) -> (model: InspectorModel, task: Task<Void, Never>) {
  let model = InspectorModel(bridge: bridge, pollInterval: .milliseconds(10))
  return (model, Task { await model.follow() })
}

/// Waits until the condition holds.
@MainActor
func wait(
  _ description: String, limit: Duration = .seconds(5), _ condition: () -> Bool
) async throws {
  let deadline = ContinuousClock.now + limit
  while !condition() {
    guard ContinuousClock.now < deadline else { throw WaitError(description: description) }
    try await Task.sleep(for: .milliseconds(5))
  }
}

struct WaitError: Error, CustomStringConvertible {
  let description: String
}
