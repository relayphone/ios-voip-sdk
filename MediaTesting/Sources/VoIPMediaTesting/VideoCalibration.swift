import Darwin
public import Foundation
import Synchronization

/// A bounded, same-clock measurement report; it contains no acceptance thresholds or inferred passes.
public final class VideoCalibration: Sendable {
  /// One bounded failing synthetic plane for codec/teardown diagnosis; data may be truncated.
  public struct CorruptFrame: Codable, Sendable {
    /// Actual decoded geometry.
    public let width: Int, height: Int, stride: Int
    /// At most 96 KiB of one failing plane, never continuous video.
    public let luma: Data
  }
  /// Result of pixel decoding with an optional bounded failure sample.
  public struct Image: Sendable {
    fileprivate let marker: VideoMarker?
    let provenance: VideoImageProvenance
    fileprivate let corruptFrame: CorruptFrame?
    /// Decodes actual pixels, retaining a bounded sample only on failure.
    public static func decode(
      luma: [UInt8], width: Int, height: Int, stride: Int,
      u: VideoImageProvenance.Plane? = nil, v: VideoImageProvenance.Plane? = nil,
      bufferType: VideoImageProvenance.BufferType = .luma, mediaTimestampNs: Int64? = nil,
      rtpTimestamp: UInt32? = nil
    ) -> Self {
      let marker = try? VideoMarker.decode(luma: luma, width: width, height: height, stride: stride)
      let provenance = VideoImageProvenance(
        y: .init(bytes: luma, width: width, height: height, stride: stride), u: u, v: v,
        bufferType: bufferType, mediaTimestampNs: mediaTimestampNs, rtpTimestamp: rtpTimestamp,
        decoded: marker != nil)
      return Self(
        marker: provenance.classification == .source ? marker : nil, provenance: provenance,
        corruptFrame: provenance.classification == .ambiguous
          ? CorruptFrame(
            width: width, height: height,
            stride: stride, luma: Data(luma.prefix(96 * 1024))) : nil)
    }
  }
  /// One original decoded callback. A corrupt image still occupies an arrival row.
  public struct Arrival: Codable, Sendable {
    /// Pixel identity, absent when decoding failed.
    public let marker: VideoMarker?
    /// Actual per-callback geometry, plane completeness, bounded samples and classification.
    public let provenance: VideoImageProvenance
    /// Actual callback entry on the named observation clock.
    public let atUs: UInt64
  }
  /// A complete fixed window's unique, ledger-matched decoded frame rate.
  public struct Window: Codable, Sendable {
    /// Start relative to the phase clock origin.
    public let startUs: UInt64
    /// Duration actually observed; incomplete final windows are not emitted.
    public let durationUs: UInt64
    /// Unique valid frames per second, never counting frozen duplicates.
    public let uniqueFPS: Double
  }
  /// Process-wide resource sample; it is not encoder-only CPU or device energy.
  public struct Resources: Codable, Sendable {
    /// Cumulative user plus system CPU time in seconds.
    public let cpuSeconds: Double
    /// Process peak resident set size in bytes.
    public let peakRSSBytes: Int64
    /// Reads the current process; nil explicitly means sampling failed.
    public static func sample() -> Self? {
      var usage = rusage()
      guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
      let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
      let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
      return Self(cpuSeconds: user + system, peakRSSBytes: Int64(usage.ru_maxrss))
    }
  }
  /// Lifecycle facts recorded at the actual app/receiver boundary, never synthesized from silence.
  public enum Lifecycle: String, Codable, Hashable, Sendable {
    case receiverAttached, receiverHeartbeat, receiverDetached, publicationMuted,
      publicationUnpublished, republished
  }
  /// Original lifecycle observation on the shared clock.
  public struct Event: Codable, Sendable {
    /// Actual observed action.
    public let kind: Lifecycle
    /// Monotonic time in microseconds.
    public let atUs: UInt64
  }
  /// All bounded evidence and aggregate measurements for later calibration and oracle evaluation.
  public struct Receipt: Encodable, Sendable {
    /// Clock shared by ledger, callback arrivals and lifecycle observations.
    public let clockID: UUID
    /// Source order and final producer boundary.
    public let source: VideoSourceLedger
    /// Callback rows, including corrupt, stale and duplicate frames.
    public let arrivals: [Arrival]
    /// Lifecycle actions; a missing heartbeat or unpublish stays missing.
    public let lifecycle: [Event]
    /// Phase anchor used for first-frame timing.
    public let anchorAtUs: UInt64
    /// Counter fence excludes pre-event seeds even when source timestamps are equal.
    public let afterCounter: UInt32?
    /// Snapshot end, including the final otherwise-silent gap.
    public let observedAtUs: UInt64
    /// Same-clock first fresh decoded arrival minus anchor; nil if unobserved.
    public let firstFrameLatencyUs: UInt64?
    /// Complete fixed-window frame rates.
    public let windows: [Window]
    /// Largest unique-frame arrival interval, including phase edges.
    public let maximumGapUs: UInt64
    /// Largest matched source-generation to decoded-arrival duration; nil if unobserved.
    public let maximumPipelineResidenceUs: UInt64?
    /// Latest matched pre-boundary arrival minus stop; nil before stop or with ambiguous post-stop pixels.
    public let preBoundaryDrainUs: UInt64?
    /// Frames with source counters beyond the frozen boundary, even if absent from the source ledger.
    public let postBoundaryFrames: Int
    /// Corrupt pixels cannot establish which side of the privacy boundary they belong to.
    public let corruptFrames: Int
    /// Positively uniform non-source images; counted but excluded from all source metrics.
    public let contentFreeFrames: Int
    /// Post-stop callbacks whose source order is unknown; these cannot qualify drain.
    public let ambiguousBoundaryFrames: Int
    /// First failing pixel plane, bounded separately from arrival metadata.
    public let firstCorruptFrame: CorruptFrame?
    /// Foreign identities or counters/timestamps absent from the original source ledger.
    public let unmatchedFrames: Int
    /// Repeated matched source counters; these never increase the frame rate.
    public let duplicateFrames: Int
    /// Any evidence overflow invalidates subsequent qualification; no rows are silently evicted.
    public let overflow: Bool
    /// Maximum simultaneous decoder callbacks, including those waiting for the measurement lock.
    public let queueHighWaterMark: Int
    /// Resources sampled before the phase, or nil on failure.
    public let resourcesAtStart: Resources?
    /// Resources sampled at report time, or nil on failure.
    public let resourcesAtEnd: Resources?
  }
  /// Invalid clock/time domains cannot be turned into latency or drain measurements.
  public enum Failure: Error { case clockMismatch, time, window }
  private struct State {
    var arrivals: [Arrival] = []
    var events: [Event] = []
    var overflow = false
    var pending = 0
    var highWater = 0
    var firstCorruptFrame: CorruptFrame?
  }
  private let state = Mutex(State())
  private let clock: MediaObservationClock
  private let resources = Resources.sample()
  /// The receiver must share this clock with its source for same-process calibration.
  public init(observationClock: MediaObservationClock) { clock = observationClock }
  /// Microseconds on the existing observation clock; calibration invocations are bounded in duration.
  public var nowUs: UInt64 { UInt64(max(0, clock.milliseconds * 1000)) }
  /// Records an actual lifecycle observation; repeated health checks are bounded to 4096 rows.
  public func record(_ kind: Lifecycle) {
    state.withLock {
      if $0.events.count < 4096 {
        $0.events.append(Event(kind: kind, atUs: nowUs))
      } else {
        $0.overflow = true
      }
    }
  }
  /// Decodes actual pixels synchronously; callback backlog and corrupt frames remain visible.
  public func receive(luma: [UInt8], width: Int, height: Int, stride: Int) {
    receiveDecoded {
      Image.decode(luma: luma, width: width, height: height, stride: stride)
    }
  }
  /// Records callback entry and backlog before native pixel conversion or copying.
  public func receiveDecoded(_ decode: () -> Image) {
    let at = nowUs
    state.withLock {
      $0.pending += 1
      $0.highWater = max($0.highWater, $0.pending)
    }
    let image = decode()
    state.withLock {
      $0.pending -= 1
      if $0.arrivals.count < 4096 {
        $0.arrivals.append(Arrival(marker: image.marker, provenance: image.provenance, atUs: at))
        if $0.firstCorruptFrame == nil { $0.firstCorruptFrame = image.corruptFrame }
      } else {
        $0.overflow = true
      }
    }
  }
  /// Snapshots original evidence. Call only after joining callbacks or while retaining the live observer.
  /// Window length is a measurement input, not a frame-rate or drain acceptance threshold.
  public func receipt(
    source: VideoSourceLedger, anchor: VideoSourceLedger.Anchor, window: Duration = .seconds(1)
  )
    throws(Failure) -> Receipt
  {
    guard source.clockID == clock.id, anchor.clockID == clock.id else { throw .clockMismatch }
    let anchorAtUs = anchor.atUs
    let end = nowUs
    let parts = window.components
    let duration = Double(parts.seconds) * 1e6 + Double(parts.attoseconds) / 1e12
    guard duration >= 1, duration <= 180_000_000 else { throw .window }
    let step = UInt64(duration)
    guard end >= anchorAtUs, end - anchorAtUs <= 180_000_000 else { throw .time }
    guard (end - anchorAtUs) / step <= 4096 else { throw .window }
    let snapshot = state.withLock {
      ($0.arrivals, $0.events, $0.overflow, $0.highWater, $0.pending, $0.firstCorruptFrame)
    }
    let arrivals = snapshot.0.sorted { $0.atUs < $1.atUs }
    guard arrivals.allSatisfy({ $0.atUs <= end }),
      source.generated.allSatisfy({ $0.sourceTimeUs <= end }),
      source.stoppedAtUs.map({ $0 <= end }) ?? true
    else { throw .time }
    let originals = Set(source.generated)
    var seen: Set<VideoMarker> = []
    var fresh: [Arrival] = []
    var corrupt = 0
    var contentFree = 0
    var unmatched = 0
    var duplicates = 0
    var postBoundary = 0
    var ambiguous = 0
    var residence: UInt64?
    var drain = source.stoppedAtUs.map { _ in UInt64(0) }
    for arrival in arrivals {
      if arrival.provenance.classification == .contentFree {
        contentFree += 1
        continue
      }
      guard let marker = arrival.marker else {
        corrupt += 1
        if let stop = source.stoppedAtUs, arrival.atUs >= stop { ambiguous += 1 }
        continue
      }
      if source.isAfterBoundary(marker) { postBoundary += 1 }
      guard originals.contains(marker), arrival.atUs >= marker.sourceTimeUs else {
        unmatched += 1
        if let stop = source.stoppedAtUs, arrival.atUs >= stop, !source.isAfterBoundary(marker) {
          ambiguous += 1
        }
        continue
      }
      residence = max(residence ?? 0, arrival.atUs - marker.sourceTimeUs)
      if let stop = source.stoppedAtUs, arrival.atUs >= stop {
        drain = max(drain ?? 0, arrival.atUs - stop)
      }
      guard seen.insert(marker).inserted else {
        duplicates += 1
        continue
      }
      if arrival.atUs >= anchorAtUs, marker.sourceTimeUs >= anchorAtUs,
        anchor.afterCounter.map({ marker.counter > $0 }) ?? true,
        arrival.atUs < (source.stoppedAtUs ?? end + 1)
      {
        fresh.append(arrival)
      }
    }
    var windows: [Window] = []
    var start = anchorAtUs
    let onEnd = max(anchorAtUs, source.stoppedAtUs ?? end)
    while onEnd - start >= step {
      let count = fresh.filter { $0.atUs >= start && $0.atUs < start + step }.count
      let attached =
        snapshot.1.filter {
          $0.atUs <= start && [.receiverAttached, .receiverDetached].contains($0.kind)
        }.last?.kind == .receiverAttached
      let detachedDuringWindow = snapshot.1.contains {
        $0.kind == .receiverDetached && $0.atUs > start && $0.atUs < start + step
      }
      if attached && !detachedDuringWindow {
        windows.append(
          Window(startUs: start, durationUs: step, uniqueFPS: Double(count) * 1e6 / Double(step)))
      }
      start += step
    }
    let times = [anchorAtUs] + fresh.map(\.atUs) + [onEnd]
    let gap = zip(times, times.dropFirst()).map { $1 - $0 }.max() ?? 0
    return Receipt(
      clockID: clock.id, source: source, arrivals: arrivals, lifecycle: snapshot.1,
      anchorAtUs: anchorAtUs, afterCounter: anchor.afterCounter, observedAtUs: end,
      firstFrameLatencyUs: fresh.first.map { $0.atUs - anchorAtUs },
      windows: windows, maximumGapUs: gap, maximumPipelineResidenceUs: residence,
      preBoundaryDrainUs: ambiguous == 0 ? drain : nil, postBoundaryFrames: postBoundary,
      corruptFrames: corrupt, contentFreeFrames: contentFree,
      ambiguousBoundaryFrames: ambiguous, firstCorruptFrame: snapshot.5,
      unmatchedFrames: unmatched, duplicateFrames: duplicates,
      overflow: snapshot.2 || snapshot.4 != 0,
      queueHighWaterMark: snapshot.3, resourcesAtStart: resources,
      resourcesAtEnd: Resources.sample())
  }
}
