import Foundation
import Testing
import VoIPCore

@Suite struct JSONValueTests {
  private let nested: JSONValue = [
    "room": "room-1", "attempt": 2, "ratio": -0.25, "recorded": false, "fallback": .null,
    "route": ["region": "eu", "hops": ["sip", 1, true, .null, [:], []]],
  ]

  private func decode(_ json: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
  }

  private func encode(_ value: JSONValue) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  @Test(arguments: [
    ("null", JSONValue.null), ("true", .bool(true)), ("false", .bool(false)), ("0", .number(0)),
    ("1", .number(1)), ("-2.5e3", .number(-2500)), (#""1""#, .string("1")),
    (#""""#, .string("")), ("[]", .array([])), ("{}", .object([:])),
    (#"[1,"a",[null]]"#, .array([.number(1), .string("a"), .array([.null])])),
    (#"{"a":{"b":false}}"#, .object(["a": .object(["b": .bool(false)])])),
  ])
  func decodesEachKind(_ json: String, _ expected: JSONValue) throws {
    #expect(try decode(json) == expected)
  }

  @Test func encodesAsJSON() throws {
    #expect(
      try encode(nested)
        == #"{"attempt":2,"fallback":null,"ratio":-0.25,"recorded":false,"#
        + #""room":"room-1","route":{"hops":["sip",1,true,null,{},[]],"region":"eu"}}"#)
  }

  @Test func roundTripsThroughJSON() throws {
    #expect(try decode(encode(nested)) == nested)
    let metadata: [String: JSONValue] = ["call": nested, "list": [nested, nested]]
    let data = try JSONEncoder().encode(metadata)
    #expect(try JSONDecoder().decode([String: JSONValue].self, from: data) == metadata)
  }

  @Test func refusesNumbersThatJSONCantHold() {
    #expect(throws: EncodingError.self) { try encode(.number(.infinity)) }
    #expect(throws: EncodingError.self) { try encode(["ratio": .number(.nan)]) }
  }

  @Test func literalsMakeTheMatchingCases() {
    let room = 7
    let literal: JSONValue = [
      "room": "room-\(room)", "attempt": 2, "ratio": 0.5, "recorded": true, "fallback": .null,
      "hops": ["sip", 1],
    ]
    let explicit = JSONValue.object([
      "room": .string("room-7"), "attempt": .number(2), "ratio": .number(0.5),
      "recorded": .bool(true), "fallback": .null, "hops": .array([.string("sip"), .number(1)]),
    ])
    #expect(literal == explicit)
    #expect(Set<JSONValue>([1, 1.0, "1", true]).count == 3)
  }

  @Test func metadataReadsByMatching() {
    let call = Call(
      id: callID, isIncoming: true, parties: [alice], status: .ringing,
      metadata: ["room": "room-1", "route": ["region": "eu"]])
    guard case .string(let room)? = call.metadata["room"],
      case .object(let route)? = call.metadata["route"],
      case .string(let region)? = route["region"]
    else {
      Issue.record("The metadata has a room and a route's region")
      return
    }
    #expect(room == "room-1")
    #expect(region == "eu")
    #expect(call.metadata["missing"] == nil)
  }
}
