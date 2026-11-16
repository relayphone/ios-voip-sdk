/// Original callback timing and PCM levels for selecting continuously observed windows.
/// Records never fill intervals without callbacks or substitute silence for missing media.
public struct MediaPCMCallbackEvidence: Codable, Sendable {
  /// One actual PCM callback, before any host-side window selection.
  public struct Frame: Codable, Sendable {
    /// Callback entry time in seconds from the probe's shared monotonic origin.
    public let atSeconds: Double
    /// Per-channel sample position from the start of this probe window.
    public let sampleOffset: Int
    /// Number of frames delivered by this callback, per channel.
    public let frameCount: Int
    /// Actual buffer sample rate.
    public let sampleRate: Double
    /// Actual buffer channel count.
    public let channels: Int
    /// Sum of squared original samples across all channels.
    public let energy: Double
    /// Largest absolute original sample across all channels.
    public let peak: Double
  }
  /// Callback history, bounded to 8192 entries. Consumers must reject overflow.
  public private(set) var frames: [Frame] = []
  /// Callbacks not retained after the bound was reached; never silently discarded.
  public private(set) var droppedFrames = 0
  private var sampleOffset = 0
  /// Starts a fresh history for a new probe window.
  public init() {}
  /// Records measurements made by the actual audio callback, without normalizing PCM.
  mutating func record(
    atSeconds: Double, frameCount: Int, sampleRate: Double, channels: Int,
    energy: Double, peak: Double
  ) {
    defer { sampleOffset += frameCount }
    guard frames.count < 8192 else {
      droppedFrames += 1
      return
    }
    frames.append(
      Frame(
        atSeconds: atSeconds, sampleOffset: sampleOffset, frameCount: frameCount,
        sampleRate: sampleRate, channels: channels, energy: energy, peak: peak))
  }
}
