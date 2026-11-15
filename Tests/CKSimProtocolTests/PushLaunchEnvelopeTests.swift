import Foundation
import Testing

@testable import CKSimProtocol

struct PushLaunchEnvelopeTests {
  let id = UUID()
  let payload = PushPayload(fields: ["callId": .string("cold-call"), "aps": .object([:])])

  func make(
    version: PushLaunchEnvelope.Version = .deliveryPlan,
    delivery: PushDeliveryFaults = .none, ids: [UUID]? = nil,
    created: Int64 = 1000, expires: Int64 = 31_000
  ) throws -> PushLaunchEnvelope {
    try PushLaunchEnvelope(
      version: version, id: id, runID: "cold-run", bundleID: "com.example.calls",
      createdAtMS: created, expiresAtMS: expires, mustReport: true, payload: payload,
      delivery: delivery, deliveryIDs: ids)
  }

  @Test func originalFormatPreservesItsExactKeysAndDecodesWithoutFaults() throws {
    let envelope = try make(version: .singleDelivery)
    let data = try JSONEncoder().encode(envelope)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(
      Set(object.keys)
        == Set([
          "schemaVersion", "id", "runID", "bundleID", "createdAtMS", "expiresAtMS", "mustReport",
          "payload",
        ]))
    #expect(try JSONDecoder().decode(PushLaunchEnvelope.self, from: data) == envelope)
    #expect(envelope.delivery == .none)
    #expect(envelope.deliveryIDs == [id])
  }

  @Test func deliveryPlanPreservesApplicationDataAndStableDuplicateIdentities() throws {
    let faults = try PushDeliveryFaults(delayMS: 200, drop: true, duplicate: 2, spacingMS: 50)
    let ids = [id, UUID(), UUID()]
    let original = try make(delivery: faults, ids: ids)
    let decoded = try JSONDecoder().decode(
      PushLaunchEnvelope.self, from: JSONEncoder().encode(original))
    #expect(decoded == original)
    #expect(decoded.payload == payload)
    #expect(decoded.deliveryIDs == ids)
    #expect(decoded.delivery.drop)
    #expect(decoded.mustReport)
  }

  @Test func duplicatePlanRequiresExactlyOneUniqueIDPerDelivery() throws {
    let faults = try PushDeliveryFaults(duplicate: 1)
    for ids in [[id], [id, id], [UUID(), id], [id, UUID(), UUID()]] {
      #expect(throws: PushLaunchEnvelope.ValidationError.invalidDeliveries) {
        try make(delivery: faults, ids: ids)
      }
    }
    #expect(throws: PushLaunchEnvelope.ValidationError.invalidDeliveries) {
      try make(version: .singleDelivery, delivery: faults, ids: [id, UUID()])
    }
  }

  @Test(arguments: [(Int64(-1), Int64(1000)), (1000, 1000), (1000, 31_001)])
  func invalidFreshnessCannotBeConstructed(times: (Int64, Int64)) {
    #expect(throws: PushLaunchEnvelope.ValidationError.invalidLifetime) {
      try make(created: times.0, expires: times.1)
    }
  }

  @Test func freshnessAndTargetAreCheckedAtClaimTime() throws {
    let envelope = try make()
    try envelope.validate(runID: "cold-run", bundleID: "com.example.calls", nowMS: 0)
    try envelope.validate(runID: "cold-run", bundleID: "com.example.calls", nowMS: 30_999)
    #expect(throws: PushLaunchEnvelope.ValidationError.expired) {
      try envelope.validate(runID: "cold-run", bundleID: "com.example.calls", nowMS: 31_000)
    }
    #expect(throws: PushLaunchEnvelope.ValidationError.expired) {
      try make(created: 2000, expires: 3000).validate(
        runID: "cold-run", bundleID: "com.example.calls", nowMS: 999)
    }
    #expect(throws: PushLaunchEnvelope.ValidationError.invalidIdentity) {
      try envelope.validate(runID: "old-run", bundleID: "com.example.calls", nowMS: 1000)
    }
    #expect(throws: PushLaunchEnvelope.ValidationError.invalidIdentity) {
      try envelope.validate(runID: "cold-run", bundleID: "com.example.other", nowMS: 1000)
    }
  }

  @Test func malformedWirePlansCannotBypassValidation() throws {
    let data = try JSONEncoder().encode(make())
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for change: [String: Any] in [
      ["schemaVersion": 3], ["extra": true], ["mustReport": 1], ["runID": "../escape"],
      ["bundleID": ""],
      ["payload": []], ["expiresAtMS": 1000],
      ["delivery": ["delayMS": 0, "drop": false, "duplicate": 101, "spacingMS": 0]],
      ["delivery": ["delayMS": 0, "drop": false, "duplicate": 0, "spacingMS": 1]],
      ["deliveryIDs": [UUID().uuidString]],
      ["delivery": ["delayMS": 0, "drop": false, "duplicate": 0, "spacingMS": 0, "extra": false]],
    ] {
      let altered = try JSONSerialization.data(
        withJSONObject: object.merging(change) { _, new in new })
      #expect(throws: (any Error).self) {
        try JSONDecoder().decode(PushLaunchEnvelope.self, from: altered)
      }
    }
  }

  @Test func maximumDuplicatePlanCannotExceedTheEnvelopeFileLimit() throws {
    let ids = [id] + (0..<100).map { _ in UUID() }
    #expect(throws: PushLaunchEnvelope.ValidationError.oversizedEnvelope) {
      try PushLaunchEnvelope(
        id: id, runID: "run", bundleID: "com.example.calls", createdAtMS: 0,
        expiresAtMS: 30_000, mustReport: true,
        payload: PushPayload(fields: ["data": .string(String(repeating: "a", count: 5000))]),
        delivery: PushDeliveryFaults(duplicate: 100), deliveryIDs: ids)
    }
  }

  @Test func oversizedPayloadCannotBeStaged() {
    #expect(throws: PushLaunchEnvelope.ValidationError.oversizedPayload) {
      try PushLaunchEnvelope(
        id: id, runID: "run", bundleID: "com.example.calls", createdAtMS: 0,
        expiresAtMS: 30_000, mustReport: true,
        payload: PushPayload(fields: ["data": .string(String(repeating: "a", count: 5120))]))
    }
  }
}
