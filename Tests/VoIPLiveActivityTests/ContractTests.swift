import Foundation
import Testing
import VoIPCore

@testable import VoIPLiveActivity

/// The JSON contract with the app's servers, in `docs/contracts/call-preview-activity.json`.
@Suite struct ContractTests {
  /// The contract file.
  struct Contract: Decodable {
    struct Vector: Decodable, CustomTestStringConvertible {
      let name: String
      let json: JSONValue
      let canonical: JSONValue?

      var testDescription: String { name }
    }

    let attributesType: String
    let payloads: [String: JSONValue]
    let attributes: [Vector]
    let contentStates: [Vector]
  }

  static let contract: Contract = {
    let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "docs/contracts/call-preview-activity.json")
    do {
      return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))
    } catch {
      preconditionFailure("The contract file is readable: \(error)")
    }
  }()

  /// The `aps` dictionary of one of the contract's payloads.
  private func aps(_ name: String) throws -> [String: JSONValue] {
    let payload = try #require(Self.contract.payloads[name])
    guard case .object(let body) = payload, case .object(let aps)? = body["aps"] else {
      Issue.record("The \(name) payload has an aps dictionary")
      return [:]
    }
    return aps
  }

  @Test func namesTheAttributesType() throws {
    #expect(Self.contract.attributesType == String(describing: CallPreviewAttributes.self))
    #expect(try aps("start")["attributes-type"] == .string(Self.contract.attributesType))
  }

  @Test func startPayloadDecodesToTheDocumentedPreview() throws {
    let aps = try aps("start")
    #expect(aps["event"] == "start")
    let attributes = try decode(CallPreviewAttributes.self, try #require(aps["attributes"]))
    let state = try decode(
      CallPreviewAttributes.ContentState.self, try #require(aps["content-state"]))
    #expect(
      attributes
        == CallPreviewAttributes(
          callID: callID, parties: [alice], metadata: ["room": "room-1"]))
    #expect(
      state
        == CallPreviewAttributes.ContentState(
          status: .filtered, startedAt: startedAt, statusText: "Your assistant is answering",
          isJoinable: true))
    #expect(attributes.fits(with: state))
  }

  @Test func updateAndEndPayloadsDecode() throws {
    let update = try decode(
      CallPreviewAttributes.ContentState.self, try #require(try aps("update")["content-state"]))
    #expect(update.status == .filtered)
    #expect(update.snippet == "They asked whether you can call back after six.")
    #expect(update.isJoinable)

    let end = try aps("end")
    #expect(end["event"] == "end")
    let final = try decode(
      CallPreviewAttributes.ContentState.self, try #require(end["content-state"]))
    #expect(final.status == .ended)
    #expect(!final.isJoinable)
    #expect(final.startedAt == startedAt)
  }

  @Test func payloadDatesAreUnixSeconds() throws {
    let start = try aps("start")
    guard case .number(let timestamp)? = start["timestamp"],
      case .object(let state)? = start["content-state"],
      case .number(let started)? = state["startedAt"]
    else {
      Issue.record("The start payload has numeric dates")
      return
    }
    #expect(started < timestamp)
    #expect(timestamp - started < 60)
  }

  @Test(arguments: contract.attributes)
  func attributesVector(_ vector: Contract.Vector) throws {
    try check(vector, as: CallPreviewAttributes.self)
  }

  @Test(arguments: contract.contentStates)
  func contentStateVector(_ vector: Contract.Vector) throws {
    try check(vector, as: CallPreviewAttributes.ContentState.self)
  }

  /// Checks that a vector decodes to its canonical form, which the SDK writes back, or fails to
  /// decode when it has none.
  private func check<Value: Codable & Equatable>(_ vector: Contract.Vector, as type: Value.Type)
    throws
  {
    guard let canonical = vector.canonical else {
      #expect(throws: DecodingError.self) { try decode(type, vector.json) }
      return
    }
    let value = try decode(type, vector.json)
    #expect(try decode(type, canonical) == value)
    #expect(try encode(value) == canonical)
  }
}

/// Decodes a value from JSON, as the system does: with `JSONDecoder`'s default strategies.
func decode<Value: Decodable>(_ type: Value.Type, _ json: JSONValue) throws -> Value {
  try JSONDecoder().decode(type, from: JSONEncoder().encode(json))
}

/// Encodes a value with `JSONEncoder`'s default strategies, as JSON values.
func encode(_ value: some Encodable) throws -> JSONValue {
  try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}
