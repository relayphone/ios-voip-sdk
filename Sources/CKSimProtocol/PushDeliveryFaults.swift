/// Delivery controls for one synthetic VoIP push. These do not alter its application payload.
public struct PushDeliveryFaults: Equatable, Sendable {
  /// Milliseconds before the first delivery, measured from command acceptance.
  public let delayMS: Int
  /// Journal each attempted delivery as dropped without invoking PushKit.
  public let drop: Bool
  /// Additional deliveries of the same payload after the original.
  public let duplicate: Int
  /// Milliseconds between consecutive deliveries.
  public let spacingMS: Int

  /// One immediate delivery with no faults.
  public static let none = Self()
  private init() {
    delayMS = 0
    drop = false
    duplicate = 0
    spacingMS = 0
  }

  /// Requires nonnegative timings, at most 100 duplicates and a schedule within 120 seconds.
  /// Spacing requires at least one duplicate. Dropping may combine with any valid schedule.
  public init(delayMS: Int = 0, drop: Bool = false, duplicate: Int = 0, spacingMS: Int = 0)
    throws(ValidationError)
  {
    guard (0...120_000).contains(delayMS), (0...120_000).contains(spacingMS),
      (0...100).contains(duplicate), duplicate > 0 || spacingMS == 0,
      delayMS + duplicate * spacingMS <= 120_000
    else { throw .invalidSchedule }
    self.delayMS = delayMS
    self.drop = drop
    self.duplicate = duplicate
    self.spacingMS = spacingMS
  }

  /// A schedule outside the supported bounds.
  public enum ValidationError: Error, Sendable { case invalidSchedule }
}

extension PushDeliveryFaults: Codable {
  private enum CodingKeys: String, CodingKey { case delayMS, drop, duplicate, spacingMS }

  /// Decodes a complete delivery plan through the same bounds as command input.
  public init(from decoder: any Decoder) throws {
    let keys = try decoder.container(keyedBy: EnvelopeKey.self).allKeys.map(\.stringValue)
    guard Set(keys) == Set(["delayMS", "drop", "duplicate", "spacingMS"]) else {
      throw ValidationError.invalidSchedule
    }
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      delayMS: values.decode(Int.self, forKey: .delayMS),
      drop: values.decode(Bool.self, forKey: .drop),
      duplicate: values.decode(Int.self, forKey: .duplicate),
      spacingMS: values.decode(Int.self, forKey: .spacingMS))
  }
}
