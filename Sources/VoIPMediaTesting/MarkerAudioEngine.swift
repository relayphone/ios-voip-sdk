#if DEBUG && os(iOS) && targetEnvironment(simulator)
  public import AVFAudio
  #if SWIFT_PACKAGE
    public import LiveKit
  #else
    public import LiveKitClient
  #endif
  import Synchronization

  /// Replaces capture with the shared tones-v2 emission and observes PCM after LiveKit's output mixer.
  ///
  /// Install once before creating a room, after the default session and mixer observers.
  /// This uses the ordinary device graph; it never activates the audio session.
  public final class MarkerAudioEngine: AudioEngineObserver {
    private struct Graph {
      var next: (any AudioEngineObserver)?
      var source: AVAudioSourceNode?
      var inputClock: AVAudioMixerNode?
      var output: AVAudioMixerNode?
    }
    private let graph = Mutex(Graph())
    private final class MarkerClock: Sendable {
      let sampleIndex = Mutex<Int64>(0)
    }
    private let clock = MarkerClock()
    private let probe: MediaAudioProbe
    private let frequencies: [Double]

    public var generatedSamples: Int64 { clock.sampleIndex.withLock { $0 } }

    public var next: (any AudioEngineObserver)? {
      get { graph.withLock { $0.next } }
      set { graph.withLock { $0.next = newValue } }
    }

    /// Creates hooks without starting capture, output or the engine.
    public init(probe: MediaAudioProbe, frequencies: [Double]) {
      precondition(
        frequencies.count == 12 && frequencies.allSatisfy { [650, 950, 1350, 1850].contains($0) })
      self.probe = probe
      self.frequencies = frequencies
    }

    public func engineWillConnectInput(
      _ engine: AVAudioEngine, src: AVAudioNode?, dst: AVAudioNode,
      format: AVAudioFormat, context: [AnyHashable: Any]
    ) -> Int {
      let rate = format.sampleRate
      guard rate >= 8000, rate <= 96000, rate.truncatingRemainder(dividingBy: 50) == 0,
        format.commonFormat == .pcmFormatFloat32, let src
      else { return -1 }
      graph.withLock { state in
        if let source = state.source, source.engine === engine { engine.detach(source) }
        if let inputClock = state.inputClock, inputClock.engine === engine {
          engine.detach(inputClock)
        }
        state.source = nil
        state.inputClock = nil
      }
      let clock = clock
      let emission = (0..<Int(rate / 50 * 51)).map {
        MarkerSignal.emissionSample(Int64($0), rate: rate, frequencies: frequencies)
      }
      let source = AVAudioSourceNode(format: format) { _, _, count, buffers in
        clock.sampleIndex.withLock { sample in
          let output = UnsafeMutableAudioBufferListPointer(buffers)
          for frame in 0..<Int(count) {
            let value = emission[Int(sample % Int64(emission.count))]
            for buffer in output {
              guard let data = buffer.mData else { continue }
              let samples = data.assumingMemoryBound(to: Float.self)
              for channel in 0..<Int(buffer.mNumberChannels) {
                samples[frame * Int(buffer.mNumberChannels) + channel] = value
              }
            }
            sample += 1
          }
        }
        return 0
      }
      engine.attach(source)
      // AVAudioSinkNode must remain downstream of hardware input to clock capture.
      // Keep that branch connected at zero gain; only the marker contributes PCM.
      for bus in 0..<dst.numberOfInputs { engine.disconnectNodeInput(dst, bus: bus) }
      let inputClock = AVAudioMixerNode()
      engine.attach(inputClock)
      engine.disconnectNodeOutput(src)
      engine.connect(src, to: inputClock, format: format)
      engine.connect(inputClock, to: dst, fromBus: 0, toBus: 0, format: format)
      engine.connect(source, to: dst, fromBus: 0, toBus: 1, format: format)
      inputClock.outputVolume = 0
      graph.withLock {
        $0.source = source
        $0.inputClock = inputClock
      }
      return next?.engineWillConnectInput(
        engine, src: src, dst: dst, format: format, context: context) ?? 0
    }

    public func engineWillConnectOutput(
      _ engine: AVAudioEngine, src: AVAudioNode, dst: AVAudioNode?,
      format: AVAudioFormat, context: [AnyHashable: Any]
    ) -> Int {
      guard let dst else { return -1 }
      graph.withLock { state in
        if let output = state.output, output.engine === engine {
          output.removeTap(onBus: 0)
          engine.detach(output)
        }
        state.output = nil
      }
      let meter = AVAudioMixerNode()
      engine.attach(meter)
      engine.disconnectNodeOutput(src)
      engine.connect(src, to: meter, format: format)
      engine.connect(meter, to: dst, format: format)
      let probe = probe
      meter.installTap(onBus: 0, bufferSize: 480, format: format) { buffer, _ in
        probe.receive(buffer, at: .output)
      }
      graph.withLock { $0.output = meter }
      probe.installed(.output)
      return next?.engineWillConnectOutput(
        engine, src: src, dst: dst, format: format, context: context) ?? 0
    }

    public func engineWillRelease(_ engine: AVAudioEngine) -> Int {
      graph.withLock { state in
        if let output = state.output {
          output.removeTap(onBus: 0)
          engine.detach(output)
        }
        if let source = state.source { engine.detach(source) }
        if let inputClock = state.inputClock { engine.detach(inputClock) }
        state.inputClock = nil
        state.output = nil
        state.source = nil
      }
      probe.removed(.output)
      return next?.engineWillRelease(engine) ?? 0
    }
  }
  // Pure sample calculation shared by the capture callback and native parity checks.
  enum MarkerSignal {
    static func emissionSample(_ index: Int64, rate: Double, frequencies: [Double]) -> Float {
      let pre = Int64((rate * 3 / 20).rounded(.toNearestOrAwayFromZero))
      let post = pre + Int64(rate / 50 * 36)
      let cycle = Int64(rate / 50 * 51)
      let position = index % cycle
      if position >= pre && position < post {
        return sample(position - pre, rate: rate, frequencies: frequencies)
      }
      let local = Double(position < pre ? position : position - post)
      let edge = position < pre ? local : Double(cycle - position)
      let fade = min(1, edge / (rate / 200))
      let envelope = 0.5 * (1 - cos(.pi * fade))
      return Float(0.2 * envelope * sin(2 * .pi * 400 * local / rate))
    }
    static func sample(_ index: Int64, rate: Double, frequencies: [Double]) -> Float {
      let slotSamples = Int64(rate / 50 * 3)
      let slot = Int(index / slotSamples) % frequencies.count
      let local = Double(index % slotSamples)
      let fade = min(1, min(local, Double(slotSamples) - local) / (rate / 200))
      let envelope = 0.5 * (1 - cos(.pi * fade))
      return Float(0.2 * envelope * sin(2 * .pi * frequencies[slot] * local / rate))
    }
  }
#endif
