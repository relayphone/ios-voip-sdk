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
