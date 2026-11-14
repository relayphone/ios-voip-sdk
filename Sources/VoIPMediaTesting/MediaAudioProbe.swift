#if DEBUG && os(iOS) && targetEnvironment(simulator)
  public import AVFAudio
  #if SWIFT_PACKAGE
    public import LiveKit
  #else
    public import LiveKitClient
  #endif
  import Synchronization

  /// Independent PCM observations; a decoder is not an output tap.
  public final class MediaAudioProbe: Sendable {
    public enum Stage: String, Codable, Hashable, Sendable { case decoded, output }
    public enum Failure: Error, Equatable, Sendable {
      case missingTap(Stage)
      case noFrames(Stage)
      case incompleteWindow(Stage)
      case signalMissing(Stage)
      case audioLeaked(Stage)
    }
    /// Original sample energy and callback coverage, without filling missing intervals.
    public struct Observation: Codable, Sendable {
      public var installed = false
      public var callbacks = 0
      public var samples = 0
      public var energy = 0.0
      public var frameSeconds = 0.0
      public var firstCallback: Double?
      public var lastCallback: Double?
      public var maximumGap = 0.0
      public var rms: Double { samples == 0 ? 0 : (energy / Double(samples)).squareRoot() }
    }
    /// Bounded original PCM for host-side complete-marker validation. Never pads lost callbacks.
    public struct Capture: Codable, Sendable {
      public var sampleRate = 0.0
      public var channels: [[Float]] = []
      public var formatChanged = false
      fileprivate mutating func append(_ incoming: [[Float]], rate: Double) {
        if sampleRate == 0 {
          sampleRate = rate
          channels = Array(repeating: [], count: incoming.count)
        }
        guard sampleRate == rate, channels.count == incoming.count else {
          formatChanged = true
          return
        }
        let remaining = max(0, Int(sampleRate * 3) - (channels.first?.count ?? 0))
        for channel in channels.indices {
          channels[channel].append(contentsOf: incoming[channel].prefix(remaining))
        }
      }
    }
    private struct State {
      var start = 0.0
      var values: [Stage: Observation] = [:]
      var captures: [Stage: Capture] = [:]
    }
    private let state = Mutex(State())
    private let now: @Sendable () -> Double
    /// Uses a monotonic clock; tests can advance an injected clock without sleeping.
    public init<C: Clock<Duration>>(clock: C) {
      let origin = clock.now
      now = {
        let elapsed = origin.duration(to: clock.now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
      }
    }
    public convenience init() { self.init(clock: ContinuousClock()) }
    /// Discards prior samples while preserving actual tap attachment.
    public func beginWindow() {
      let start = now()
      state.withLock { state in
        state.start = start
        state.captures = [:]
        for stage in [Stage.decoded, .output] {
          state.values[stage] = Observation(installed: state.values[stage]?.installed ?? false)
        }
      }
    }
    public func observation(_ stage: Stage) -> Observation {
      state.withLock { $0.values[stage] ?? Observation() }
    }
    public func capture(_ stage: Stage) -> Capture {
      state.withLock { $0.captures[stage] ?? Capture() }
    }
    public func expectAudio(_ stage: Stage) throws(Failure) {
      let value = try liveObservation(stage, duration: .zero)
      guard value.rms > 0.002 else { throw .signalMissing(stage) }
    }
    /// Requires live callbacks throughout the requested interval; at most 250 ms may be uncovered.
    public func expectSilence(_ stage: Stage, for duration: Duration = .zero) throws(Failure) {
      let value = try liveObservation(stage, duration: duration)
      guard value.rms < 0.001 else { throw .audioLeaked(stage) }
    }
    private func liveObservation(_ stage: Stage, duration: Duration) throws(Failure) -> Observation
    {
      let (value, start) = state.withLock { ($0.values[stage] ?? Observation(), $0.start) }
      guard value.installed else { throw .missingTap(stage) }
      guard let first = value.firstCallback, let last = value.lastCallback else {
        throw .noFrames(stage)
      }
      let elapsed = now()
      let required = Double(duration / .seconds(1))
      guard elapsed - last <= 0.25, value.maximumGap <= 0.25,
        elapsed - start >= required, required == 0 || first - start <= 0.25,
        value.frameSeconds >= max(0, required - 0.25)
      else { throw .incompleteWindow(stage) }
      return value
    }
    func installed(_ stage: Stage) {
      state.withLock { $0.values[stage, default: Observation()].installed = true }
    }
    func removed(_ stage: Stage) { state.withLock { $0.values[stage] = Observation() } }
    func receive(_ buffer: AVAudioPCMBuffer, at stage: Stage) {
      let entered = now()
      let count = Int(buffer.frameLength)
      let channels = Int(buffer.format.channelCount)
      guard count > 0, channels > 0, buffer.format.sampleRate > 0 else { return }
      var energy = 0.0
      var captured = Array(repeating: [Float](), count: channels)
      for channel in 0..<channels {
        for frame in 0..<count {
          let plane = buffer.format.isInterleaved ? 0 : channel
          let offset = buffer.format.isInterleaved ? frame * channels + channel : frame
          let value: Double
          if let pcm = buffer.floatChannelData {
            value = Double(pcm[plane][offset])
          } else if let pcm = buffer.int16ChannelData {
            value = Double(pcm[plane][offset]) / 32768
          } else {
            return
          }
          energy += value * value
          captured[channel].append(Float(value))
        }
      }
      state.withLock { state in
        guard entered >= state.start else { return }
        state.captures[stage, default: Capture()].append(captured, rate: buffer.format.sampleRate)
        var value = state.values[stage] ?? Observation()
        if let last = value.lastCallback {
          value.maximumGap = max(value.maximumGap, entered - last)
        }
        value.firstCallback = value.firstCallback ?? entered
        value.lastCallback = entered
        value.callbacks += 1
        value.samples += count * channels
        value.energy += energy
        value.frameSeconds += Double(count) / buffer.format.sampleRate
        state.values[stage] = value
      }
    }
  }

  /// A tap attached to the real room's remote track, before output mixing.
  public final class DecodedAudioProbe: AudioRenderer {
    private let probe: MediaAudioProbe
    public init(probe: MediaAudioProbe) { self.probe = probe }
    public func attach(to track: RemoteAudioTrack) {
      track.add(audioRenderer: self)
      probe.installed(.decoded)
    }
    public func render(pcmBuffer: AVAudioPCMBuffer) { probe.receive(pcmBuffer, at: .decoded) }
  }
#endif
