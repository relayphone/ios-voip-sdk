/// Bounded PCM silence attempts on one monotonic clock. Delivered frame duration covers time;
/// callback liveness remains a separate 250 ms requirement.
public struct PCMSilenceWindows: Sendable {
  public enum Verdict: String, Codable, Sendable { case silent, unobserved, leak }
  public struct Gap: Codable, Sendable {
    public let fromSeconds: Double
    public let toSeconds: Double
    public let uncoveredSeconds: Double
    public let callbackGapSeconds: Double
    public let callbackAtSeconds: Double?
  }
  public struct Tick: Codable, Sendable {
    public let seconds: Double
    public let schedulerLagSeconds: Double
  }
  public struct Window: Codable, Sendable {
    public var startSeconds: Double
    public var endSeconds: Double
    public var coveredSeconds = 0.0
    public var gaps: [Gap] = []
    public var ticks: [Tick] = []
    public var verdict = Verdict.unobserved
  }
  public private(set) var windows: [Window] = []
  public private(set) var verdict: Verdict?
  public struct Snapshot: Codable, Sendable {
    public let windows: [Window]
    public let activeWindow: Window?
    public let deadlineSeconds: Double
  }
  /// Includes an unfinished attempt so a missing final observer report remains explicit.
  public var snapshot: Snapshot {
    Snapshot(
      windows: windows, activeWindow: verdict == nil ? current : nil, deadlineSeconds: deadline)
  }
  private let duration: Double
  private let deadline: Double
  private var current: Window
  private var lastFrame: Double
  private var lastTick: Double
  private var energy = 0.0
  private var samples = 0
  /// The caller supplies the phase's existing deadline in the same clock as all observations.
  public init(start: Duration, duration: Duration, deadline: Duration) {
    precondition(duration > .zero)
    let start = Self.seconds(start)
    self.duration = Self.seconds(duration)
    self.deadline = Self.seconds(deadline)
    current = Window(startSeconds: start, endSeconds: start)
    lastFrame = start
    lastTick = start
  }
  /// Records observer scheduling diagnostics without asserting PCM coverage between callbacks.
  public mutating func tick(at time: Duration) {
    let now = Self.seconds(time)
    let tick = Tick(seconds: now, schedulerLagSeconds: max(0, now - lastTick - 0.02))
    for index in windows.indices where windows[index].endSeconds > lastTick {
      windows[index].ticks.append(tick)
    }
    lastTick = now
    guard verdict == nil else { return }
    current.ticks.append(tick)
    if now >= deadline {
      if now > lastFrame {
        current.gaps.append(
          Gap(
            fromSeconds: lastFrame, toSeconds: now,
            uncoveredSeconds: now - lastFrame, callbackGapSeconds: now - lastFrame,
            callbackAtSeconds: nil))
      }
      finish(.unobserved, at: now)
    }
  }
  /// A leak is checked before retiring a window containing a coverage or liveness gap.
  public mutating func receive(
    at time: Duration, frames: Int, sampleRate: Double, sampleCount: Int, energy: Double
  ) {
    guard verdict == nil else { return }
    let now = Self.seconds(time)
    let elapsed = now - lastFrame
    let covered = Double(frames) / sampleRate
    current.endSeconds = now
    current.coveredSeconds += covered
    let uncovered = max(0, now - current.startSeconds - current.coveredSeconds)
    let hasGap = uncovered > 0.04 || elapsed > 0.25
    if hasGap {
      current.gaps.append(
        Gap(
          fromSeconds: current.startSeconds + current.coveredSeconds, toSeconds: now,
          uncoveredSeconds: uncovered, callbackGapSeconds: elapsed, callbackAtSeconds: now))
    }
    self.energy += energy
    samples += sampleCount
    if samples > 0 && (self.energy / Double(samples)).squareRoot() >= 0.001 {
      finish(.leak, at: now)
    } else if now > deadline {
      finish(.unobserved, at: now)
    } else if hasGap {
      current.verdict = .unobserved
      windows.append(current)
      current = Window(startSeconds: now, endSeconds: now)
      self.energy = 0
      samples = 0
    } else if now >= current.startSeconds + duration {
      finish(.silent, at: now)
    }
    lastFrame = now
  }
  private mutating func finish(_ result: Verdict, at now: Double) {
    current.endSeconds = now
    current.verdict = result
    windows.append(current)
    verdict = result
  }
  private static func seconds(_ duration: Duration) -> Double {
    Double(duration / .seconds(1))
  }
}
