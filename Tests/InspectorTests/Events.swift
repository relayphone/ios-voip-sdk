import Foundation

@testable import CKSimInspector

/// A journal event for run `run` of process 123, with the given fields on top.
func event(_ sequence: Int, _ time: Double, _ name: String, _ fields: [String: Any] = [:]) throws
  -> RuntimeEvent
{
  var value: [String: Any] = [
    "schemaVersion": 1, "sequence": sequence, "runID": "run", "pid": 123,
    "bundleID": "test.fixture", "event": name, "t_ms": time,
  ]
  value.merge(fields) { _, new in new }
  return try JSONDecoder().decode(
    RuntimeEvent.self, from: JSONSerialization.data(withJSONObject: value))
}

/// The `call.changed` event `sequence` with the given fields.
func call(_ sequence: Int = 1, _ fields: [String: Any] = [:]) throws -> RuntimeEvent {
  try event(sequence, 0, "call.changed", fields)
}
