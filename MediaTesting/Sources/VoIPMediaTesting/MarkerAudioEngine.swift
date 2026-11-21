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
      var outputTapped = false
      var outputRetired = false
    }
    /// Processing snapshots at options, engine and callback boundaries.
    public let processingTimeline = MediaProcessingTimeline()
    private let graph = Mutex(Graph())
    private let emission: MarkerEmission
    private let probe: MediaAudioProbe

    /// Processing for synthetic capture, which has no acoustic echo or microphone noise.
    ///
    /// Pass these options only for this simulator source. Ordinary LiveKit capture defaults
    /// remain unchanged. Automatic gain control still exercises software processing.
    public static var syntheticCaptureOptions: AudioCaptureOptions {
      AudioCaptureOptions(
        echoCancellation: false, autoGainControl: true, noiseSuppression: false,
        echoCancellationMode: .software, autoGainControlMode: .software,
        noiseSuppressionMode: .software)
    }

    public var generatedSamples: Int64 { emission.generatedSamples }

    /// Permanently removes this call's output observer, without starting audio.
    /// A later graph callback cannot reinstall a tap after terminal release.
    public func uninstallOutputTap() {
      graph.withLock { state in
        state.outputRetired = true
        if state.outputTapped { state.output?.removeTap(onBus: 0) }
        state.outputTapped = false
        probe.removed(.output)
      }
    }

    public var next: (any AudioEngineObserver)? {
      get { graph.withLock { $0.next } }
      set { graph.withLock { $0.next = newValue } }
    }

    /// Creates hooks without starting capture, output or the engine.
    public init(probe: MediaAudioProbe, frequencies: [Double]) {
      self.probe = probe
      emission = MarkerEmission(frequencies: frequencies)
    }

    /// Atomically starts a fresh tones-v2 cycle at the next source render boundary.
    /// Already rendered PCM retains its previous marker; the graph stays connected.
    public func replaceMarker(frequencies: [Double]) {
      emission.replace(frequencies: frequencies)
    }

    public func engineWillConnectInput(
      _ engine: AVAudioEngine, src: AVAudioNode?, dst: AVAudioNode,
      format: AVAudioFormat, context: [AnyHashable: Any]
    ) -> Int {
      processingTimeline.record(.engineWillConnectInput, engineRunning: engine.isRunning)
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
      // The mixer observer has already routed the microphone. Use that input branch so
      // the marker passes through the same mute gate as microphone audio.
      let connections = engine.outputConnectionPoints(for: src, outputBus: 0)
      guard connections.count == 1, let connection = connections.first,
        let microphoneMixer = connection.node as? AVAudioMixerNode
      else { return -1 }
      let emission = emission
      emission.configure(rate: rate)
      let processingTimeline = processingTimeline
      let source = AVAudioSourceNode(format: format) { _, _, count, buffers in
        processingTimeline.recordCallback(.sourceRender)
        emission.render { samples, sample in
          let output = UnsafeMutableAudioBufferListPointer(buffers)
          for frame in 0..<Int(count) {
            let value = samples[Int(sample % Int64(samples.count))]
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
      let inputClock = AVAudioMixerNode()
      engine.attach(inputClock)
      engine.disconnectNodeOutput(src)
      engine.connect(src, to: inputClock, format: format)
      engine.connect(
        inputClock, to: microphoneMixer, fromBus: 0, toBus: connection.bus, format: format)
      engine.connect(source, to: microphoneMixer, format: format)
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
      processingTimeline.record(.engineWillConnectOutput, engineRunning: engine.isRunning)
      guard let dst else { return -1 }
      let installed = graph.withLock { state in
        guard !state.outputRetired else { return false }
        if let output = state.output, output.engine === engine {
          if state.outputTapped { output.removeTap(onBus: 0) }
          engine.detach(output)
        }
        state.output = nil
        state.outputTapped = false
        let meter = AVAudioMixerNode()
        engine.attach(meter)
        engine.disconnectNodeOutput(src)
        engine.connect(src, to: meter, format: format)
        engine.connect(meter, to: dst, format: format)
        let probe = probe
        let processingTimeline = processingTimeline
        meter.installTap(onBus: 0, bufferSize: 480, format: format) { buffer, _ in
          processingTimeline.recordCallback(.outputCallback)
          probe.receive(buffer, at: .output)
        }
        state.output = meter
        state.outputTapped = true
        probe.installed(.output)
        return true
      }
      guard installed else { return -1 }
      return next?.engineWillConnectOutput(
        engine, src: src, dst: dst, format: format, context: context) ?? 0
    }

    public func engineDidCreate(_ engine: AVAudioEngine) -> Int {
      processingTimeline.record(.engineDidCreate, engineRunning: engine.isRunning)
      return next?.engineDidCreate(engine) ?? 0
    }

    public func engineWillEnable(
      _ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool
    ) -> Int {
      processingTimeline.record(.engineWillEnable, engineRunning: engine.isRunning)
      return next?.engineWillEnable(
        engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }

    public func engineWillStart(
      _ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool
    ) -> Int {
      processingTimeline.record(.engineWillStart, engineRunning: engine.isRunning)
      return next?.engineWillStart(
        engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }

    public func engineDidStop(
      _ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool
    ) -> Int {
      processingTimeline.record(.engineDidStop, engineRunning: engine.isRunning)
      return next?.engineDidStop(
        engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }

    public func engineDidDisable(
      _ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool
    ) -> Int {
      processingTimeline.record(.engineDidDisable, engineRunning: engine.isRunning)
      return next?.engineDidDisable(
        engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }

    public func engineWillRelease(_ engine: AVAudioEngine) -> Int {
      processingTimeline.record(.engineWillRelease, engineRunning: engine.isRunning)
      graph.withLock { state in
        if let output = state.output {
          if state.outputTapped { output.removeTap(onBus: 0) }
          engine.detach(output)
        }
        if let source = state.source { engine.detach(source) }
        if let inputClock = state.inputClock { engine.detach(inputClock) }
        state.inputClock = nil
        state.output = nil
        state.outputTapped = false
        state.source = nil
        probe.removed(.output)
      }
      return next?.engineWillRelease(engine) ?? 0
    }
  }
#endif
