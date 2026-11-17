public import Foundation

/// Bounded pixel evidence for one callback; uniformity always scans every active sample.
public struct VideoImageProvenance: Codable, Sendable {
  /// Original callback buffer type, or luma supplied directly by a test.
  public enum BufferType: String, Codable, Sendable { case luma, i420, pixelBuffer, unsupported }
  /// Classification does not assert the transport origin of a content-free image.
  public enum Classification: String, Codable, Sendable { case source, contentFree, ambiguous }
  /// Complete-plane statistics plus a small diagnostic sample, excluding row padding.
  public struct Plane: Codable, Sendable {
    /// Actual layout and supplied byte count.
    public let width: Int, height: Int, stride: Int, byteCount: Int
    /// False for invalid geometry, excessive allocation or missing active samples.
    public let complete: Bool
    /// Extremes over every active sample, absent for incomplete planes.
    public let minimum: UInt8?, maximum: UInt8?
    /// At most sixteen active samples; never used to establish uniformity.
    public let sample: Data
    /// A common value exists within ±2 of every sample, including the extrema.
    public var uniform: Bool {
      guard complete, let minimum, let maximum else { return false }
      return Int(maximum) - Int(minimum) <= 4
    }
    /// Examines a whole plane within the receiver's fixed geometry and stride bounds.
    public init(bytes: [UInt8], width: Int, height: Int, stride: Int) {
      self.width = width
      self.height = height
      self.stride = stride
      byteCount = bytes.count
      complete =
        width > 0 && width <= 1920 && height > 0 && height <= 1080
        && stride >= width && stride <= 16384 && bytes.count >= stride * height
      guard complete else {
        minimum = nil
        maximum = nil
        sample = Data(bytes.prefix(16))
        return
      }
      var low = UInt8.max
      var high = UInt8.min
      var prefix: [UInt8] = []
      for row in 0..<height {
        for column in 0..<width {
          let value = bytes[row * stride + column]
          low = min(low, value)
          high = max(high, value)
          if prefix.count < 16 { prefix.append(value) }
        }
      }
      minimum = low
      maximum = high
      sample = Data(prefix)
    }
  }
  /// Layout and bounded evidence for the actual decoded planes; absent chroma was not retained.
  public let y: Plane, u: Plane?, v: Plane?
  /// Original callback buffer type.
  public let bufferType: BufferType
  /// Original media timestamp, distinct from callback entry time.
  public let mediaTimestampNs: Int64?
  /// Original transport timestamp, when the native callback exposes it.
  public let rtpTimestamp: UInt32?
  /// Positive pixel classification; foreign decoded identities still require ledger validation.
  public let classification: Classification

  init(
    y: Plane, u: Plane?, v: Plane?, bufferType: BufferType, mediaTimestampNs: Int64?,
    rtpTimestamp: UInt32?, decoded: Bool
  ) {
    self.y = y
    self.u = u
    self.v = v
    self.bufferType = bufferType
    self.mediaTimestampNs = mediaTimestampNs
    self.rtpTimestamp = rtpTimestamp
    let chromaComplete =
      (u == nil && v == nil)
      || (y.complete && u?.complete == true && v?.complete == true
        && u?.width == (y.width + 1) / 2 && v?.width == (y.width + 1) / 2
        && u?.height == (y.height + 1) / 2 && v?.height == (y.height + 1) / 2)
    let complete = y.complete && chromaComplete && bufferType != .unsupported
    let sourceGeometry = (y.width == 160 && y.height == 120) || (y.width == 320 && y.height == 240)
    if decoded && complete {
      classification = .source
    } else if complete && !sourceGeometry && y.uniform
      && (u?.uniform ?? true) && (v?.uniform ?? true)
    {
      classification = .contentFree
    } else {
      classification = .ambiguous
    }
  }
}
