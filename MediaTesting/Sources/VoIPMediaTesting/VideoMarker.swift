import CryptoKit
public import Foundation

/// A versioned in-band identity decoded from lossy video pixels, never from transport metadata.
public struct VideoMarker: Codable, Equatable, Hashable, Sendable {
  /// Independent stream direction in the fixture.
  public enum Direction: UInt8, Codable, Sendable { case uplink, downlink }
  /// Malformed input remains distinct from an absent frame.
  public enum Failure: Error { case dimensions, corrupt, exhausted, stopped, time }
  /// Fixture identity shared by the source ledger and remote decoder.
  public let fixture: UUID
  /// Stream direction.
  public let direction: Direction
  /// A fresh value for each publication or resume phase.
  public let epoch: UInt32
  /// Strictly increasing source order, including frames never delivered.
  public let counter: UInt32
  /// Microseconds on the source ledger's named clock, bounded to exact JSON integers.
  public let sourceTimeUs: UInt64
  /// Creates an identity; timestamps outside the exact JSON integer range are rejected.
  public init(
    fixture: UUID, direction: Direction, epoch: UInt32, counter: UInt32, sourceTimeUs: UInt64
  )
    throws(Failure)
  {
    guard sourceTimeUs <= 9_007_199_254_740_991 else { throw .time }
    self.fixture = fixture
    self.direction = direction
    self.epoch = epoch
    self.counter = counter
    self.sourceTimeUs = sourceTimeUs
  }
  private enum CodingKeys: String, CodingKey {
    case fixture, direction, epoch, counter, sourceTimeUs
  }
  /// Validates wire input through the same timestamp invariant as generated markers.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let time = try values.decode(UInt64.self, forKey: .sourceTimeUs)
    guard time <= 9_007_199_254_740_991 else {
      throw DecodingError.dataCorruptedError(
        forKey: .sourceTimeUs, in: values, debugDescription: "Inexact video timestamp")
    }
    try self.init(
      fixture: values.decode(UUID.self, forKey: .fixture),
      direction: values.decode(Direction.self, forKey: .direction),
      epoch: values.decode(UInt32.self, forKey: .epoch),
      counter: values.decode(UInt32.self, forKey: .counter), sourceTimeUs: time)
  }
  private static let columns = 24, rows = 20
  private var bytes: [UInt8] {
    var id = fixture.uuid
    var result: [UInt8] = [0x56, 0x4D, 1]
    result += withUnsafeBytes(of: &id) { Array($0) }
    result.append(direction.rawValue)
    for (value, count) in [(UInt64(epoch), 4), (UInt64(counter), 4), (sourceTimeUs, 8)] {
      result += (0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    return result + SHA256.hash(data: Data(result)).prefix(8)
  }
  /// Generates packed luma with neutral chroma supplied by the capture adapter.
  /// A centered 24×20 grid uses coarse cells; remaining cells form orientation checks.
  public func luma(width: Int, height: Int) throws(Failure) -> [UInt8] {
    guard width >= 144, height >= 120, width <= 1920, height <= 1080 else { throw .dimensions }
    let bytes = bytes
    let cell = min(width / Self.columns, height / Self.rows)
    let left = (width - Self.columns * cell) / 2
    let top = (height - Self.rows * cell) / 2
    var pixels = [UInt8](repeating: 128, count: width * height)
    for index in 0..<(Self.columns * Self.rows) {
      let bit =
        index < bytes.count * 8
        ? (bytes[index / 8] >> (7 - index % 8)) & 1 : UInt8(index % 2)
      for y in 0..<cell {
        let offset =
          (top + index / Self.columns * cell + y) * width + left + index % Self.columns * cell
        for x in 0..<cell { pixels[offset + x] = bit == 0 ? 16 : 235 }
      }
    }
    return pixels
  }
  /// Reads cell interiors, verifies orientation, schema and digest, and returns the pixel identity.
  /// Dimensions and stride describe the actual decoded luma plane, including row padding.
  public static func decode(luma: [UInt8], width: Int, height: Int, stride: Int) throws(Failure)
    -> Self
  {
    guard width >= 144, height >= 120, width <= 1920, height <= 1080,
      stride >= width, stride <= 16384, luma.count >= stride * height
    else { throw .dimensions }
    let cell = min(width / columns, height / rows)
    let left = (width - columns * cell) / 2
    let top = (height - rows * cell) / 2
    var bytes = [UInt8](repeating: 0, count: 44)
    for index in 0..<(columns * rows) {
      let x = left + index % columns * cell + cell / 2
      let y = top + index / columns * cell + cell / 2
      var sum = 0
      for dy in -1...1 { for dx in -1...1 { sum += Int(luma[(y + dy) * stride + x + dx]) } }
      let value = sum / 9
      guard value <= 64 || value >= 192 else { throw .corrupt }
      let bit: UInt8 = value >= 192 ? 1 : 0
      if index < bytes.count * 8 {
        bytes[index / 8] |= bit << (7 - index % 8)
      } else if bit != UInt8(index % 2) {
        throw .corrupt
      }
    }
    guard Array(bytes.prefix(3)) == [0x56, 0x4D, 1],
      Array(SHA256.hash(data: Data(bytes.prefix(36))).prefix(8)) == Array(bytes.suffix(8)),
      let direction = Direction(rawValue: bytes[19])
    else { throw .corrupt }
    let id = bytes[3..<19].map { String(format: "%02x", $0) }.joined()
    let text =
      "\(id.prefix(8))-\(id.dropFirst(8).prefix(4))-\(id.dropFirst(12).prefix(4))-\(id.dropFirst(16).prefix(4))-\(id.suffix(12))"
    guard let fixture = UUID(uuidString: text) else { throw .corrupt }
    func integer(_ range: Range<Int>) -> UInt64 {
      range.reduce(0) { ($0 << 8) | UInt64(bytes[$1]) }
    }
    return try Self(
      fixture: fixture, direction: direction, epoch: UInt32(integer(20..<24)),
      counter: UInt32(integer(24..<28)), sourceTimeUs: integer(28..<36))
  }
}

/// Bounded original source order, serialized with the app's off/end boundary by its capture owner.
public struct VideoSourceLedger: Encodable, Sendable {
  /// Counter and time captured together before a new measurement phase; excludes pre-event seeds.
  public struct Anchor: Encodable, Sendable {
    /// Source clock identity.
    public let clockID: UUID
    /// Monotonic phase boundary.
    public let atUs: UInt64
    /// Last source counter already created at the boundary, even at the same timestamp.
    public let afterCounter: UInt32?
  }
  /// Shared monotonic clock identity; foreign receiver clocks cannot measure residence directly.
  public let clockID: UUID
  /// Original identities, including frames lost or still in flight.
  public private(set) var generated: [VideoMarker] = []
  /// Boundary time, present even when the source stopped before its first frame.
  public private(set) var stoppedAtUs: UInt64?
  /// Scheduled ticks skipped under load; counters are never reused to conceal a missed tick.
  public private(set) var skippedTicks: UInt32 = 0
  /// Generated identities whose buffer could not be submitted.
  public private(set) var rejectedSubmissions: UInt32 = 0
  private var nextCounter: UInt32 = 0
  /// Last generated counter at the atomic boundary; nil means none were generated.
  public var finalCounter: UInt32? { generated.last?.counter }
  private let fixture: UUID
  private let direction: VideoMarker.Direction
  private let epoch: UInt32
  /// Creates one phase ledger. Overflow is an error, never eviction of privacy evidence.
  public init(clockID: UUID, fixture: UUID, direction: VideoMarker.Direction, epoch: UInt32) {
    self.clockID = clockID
    self.fixture = fixture
    self.direction = direction
    self.epoch = epoch
  }
  /// Records source creation before submission. At most 4096 original frames are retained.
  public mutating func generate(atUs: UInt64) throws(VideoMarker.Failure) -> VideoMarker {
    guard stoppedAtUs == nil else { throw .stopped }
    guard nextCounter < 4096 else { throw .exhausted }
    guard atUs >= (generated.last?.sourceTimeUs ?? 0) else { throw .time }
    let marker = try VideoMarker(
      fixture: fixture, direction: direction, epoch: epoch,
      counter: nextCounter, sourceTimeUs: atUs)
    nextCounter += 1
    generated.append(marker)
    return marker
  }
  /// Captures the anchor in the source owner's serialized turn, before any new generation.
  public func anchor(atUs: UInt64) throws(VideoMarker.Failure) -> Anchor {
    guard atUs >= (generated.last?.sourceTimeUs ?? 0), atUs <= 9_007_199_254_740_991 else {
      throw .time
    }
    return Anchor(clockID: clockID, atUs: atUs, afterCounter: finalCounter)
  }
  /// Advances source order without rendering or bursting to make up missed deadlines.
  public mutating func skipTick() throws(VideoMarker.Failure) {
    guard stoppedAtUs == nil else { throw .stopped }
    guard nextCounter < 4096 else { throw .exhausted }
    nextCounter += 1
    skippedTicks += 1
  }
  /// Records an actual buffer allocation/submission rejection after generation.
  public mutating func rejectSubmission() { rejectedSubmissions += 1 }
  /// Freezes the final counter exactly once. The capture owner must serialize this against generation.
  public mutating func stop(atUs: UInt64) throws(VideoMarker.Failure) {
    guard stoppedAtUs == nil else { return }
    guard atUs >= (generated.last?.sourceTimeUs ?? 0), atUs <= 9_007_199_254_740_991 else {
      throw .time
    }
    stoppedAtUs = atUs
  }
}

extension VideoSourceLedger {
  func isAfterBoundary(_ marker: VideoMarker) -> Bool {
    stoppedAtUs != nil && marker.fixture == fixture && marker.direction == direction
      && marker.epoch == epoch
      && (finalCounter.map { marker.counter > $0 } ?? true)
  }
}
