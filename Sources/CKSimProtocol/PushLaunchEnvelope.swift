public import Foundation

/// A validated cold-launch push, independent of the installed application's JSON payload.
public struct PushLaunchEnvelope: Codable, Equatable, Sendable {
  /// The original one-delivery wire format or the format carrying a delivery plan.
  public enum Version: Int, Codable, Sendable {
    case singleDelivery = 1
    case deliveryPlan = 2
  }
  /// A malformed, oversized, mismatched or expired envelope.
  public enum ValidationError: Error, Equatable, Sendable {
    case invalidIdentity, invalidLifetime, oversizedPayload, invalidDeliveries, expired,
      invalidKeys, oversizedEnvelope
  }

  /// The envelope's supported wire format.
  public let schemaVersion: Version
  /// The request and original delivery identifier.
  public let id: UUID
  /// The runtime invocation that may claim the envelope.
  public let runID: String
  /// The application permitted to consume the envelope.
  public let bundleID: String
  /// Creation time in Unix milliseconds, used only for cross-process freshness checks.
  public let createdAtMS: Int64
  /// Exclusive freshness limit in Unix milliseconds; never a push-reporting deadline.
  public let expiresAtMS: Int64
  /// Whether metadata-capable delegates owe a new incoming report for each delivery.
  public let mustReport: Bool
  /// Application data that must be bridged successfully before scheduling.
  public let payload: PushPayload
  /// The bounded plan; version one always has one immediate delivery.
  public let delivery: PushDeliveryFaults
  /// Stable identifiers for the original and every additional delivery.
  public let deliveryIDs: [UUID]

  /// Creates a launch envelope with at most 30 seconds of freshness.
  public init(
    version: Version = .deliveryPlan, id: UUID, runID: String, bundleID: String,
    createdAtMS: Int64, expiresAtMS: Int64, mustReport: Bool, payload: PushPayload,
    delivery: PushDeliveryFaults = .none, deliveryIDs: [UUID]? = nil
  ) throws {
    guard validRuntimeRunID(runID), !bundleID.isEmpty else { throw ValidationError.invalidIdentity }
    guard createdAtMS >= 0, expiresAtMS > createdAtMS,
      expiresAtMS - createdAtMS <= 30_000
    else { throw ValidationError.invalidLifetime }
    guard try JSONEncoder().encode(payload).count <= 5120 else {
      throw ValidationError.oversizedPayload
    }
    let ids = deliveryIDs ?? [id]
    guard ids.count == delivery.duplicate + 1, ids.first == id,
      Set(ids).count == ids.count,
      version != .singleDelivery || delivery == .none
    else { throw ValidationError.invalidDeliveries }
    schemaVersion = version
    self.id = id
    self.runID = runID
    self.bundleID = bundleID
    self.createdAtMS = createdAtMS
    self.expiresAtMS = expiresAtMS
    self.mustReport = mustReport
    self.payload = payload
    self.delivery = delivery
    self.deliveryIDs = ids
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard try encoder.encode(self).count < 8192 else { throw ValidationError.oversizedEnvelope }
  }

  /// Checks the intended consumer and current freshness without changing delivery deadlines.
  public func validate(runID: String, bundleID: String, nowMS: Int64) throws(ValidationError) {
    guard self.runID == runID, self.bundleID == bundleID else { throw .invalidIdentity }
    guard nowMS >= 0, nowMS < expiresAtMS,
      nowMS >= createdAtMS || createdAtMS - nowMS <= 1000
    else { throw .expired }
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, id, runID, bundleID, createdAtMS, expiresAtMS, mustReport, payload,
      delivery, deliveryIDs
  }

  /// Reads both supported formats, applying the same validation as direct construction.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let version = try values.decode(Version.self, forKey: .schemaVersion)
    let keys = try decoder.container(keyedBy: EnvelopeKey.self).allKeys.map(\.stringValue)
    var expected = Set([
      "schemaVersion", "id", "runID", "bundleID", "createdAtMS", "expiresAtMS", "mustReport",
      "payload",
    ])
    if version == .deliveryPlan { expected.formUnion(["delivery", "deliveryIDs"]) }
    guard Set(keys) == expected else { throw ValidationError.invalidKeys }
    let id = try values.decode(UUID.self, forKey: .id)
    if version == .singleDelivery,
      values.contains(.delivery) || values.contains(.deliveryIDs)
    {
      throw ValidationError.invalidDeliveries
    }
    try self.init(
      version: version, id: id, runID: values.decode(String.self, forKey: .runID),
      bundleID: values.decode(String.self, forKey: .bundleID),
      createdAtMS: values.decode(Int64.self, forKey: .createdAtMS),
      expiresAtMS: values.decode(Int64.self, forKey: .expiresAtMS),
      mustReport: values.decode(Bool.self, forKey: .mustReport),
      payload: values.decode(PushPayload.self, forKey: .payload),
      delivery: version == .singleDelivery
        ? .none : values.decode(PushDeliveryFaults.self, forKey: .delivery),
      deliveryIDs: version == .singleDelivery
        ? [id] : values.decode([UUID].self, forKey: .deliveryIDs))
  }

  /// Preserves the original key set for single-delivery consumers.
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(schemaVersion, forKey: .schemaVersion)
    try values.encode(id, forKey: .id)
    try values.encode(runID, forKey: .runID)
    try values.encode(bundleID, forKey: .bundleID)
    try values.encode(createdAtMS, forKey: .createdAtMS)
    try values.encode(expiresAtMS, forKey: .expiresAtMS)
    try values.encode(mustReport, forKey: .mustReport)
    try values.encode(payload, forKey: .payload)
    if schemaVersion == .deliveryPlan {
      try values.encode(delivery, forKey: .delivery)
      try values.encode(deliveryIDs, forKey: .deliveryIDs)
    }
  }
}

// Allows rejecting unknown transport fields while preserving arbitrary application payload keys.
struct EnvelopeKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}
