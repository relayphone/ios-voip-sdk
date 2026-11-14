#if DEBUG && os(iOS) && targetEnvironment(simulator)
  import AVFAudio
  import CryptoKit
  import Foundation
  import Testing
  import VoIPTesting
  import LiveKit

  @testable import VoIPMediaTesting

  @Suite("Media observation evidence")
  struct ProbeTests {
    @Test
    func syntheticProcessingDoesNotChangeOrdinaryCaptureDefaults() {
      let before = AudioCaptureOptions()
      let synthetic = MarkerAudioEngine.syntheticCaptureOptions
      #expect(!synthetic.echoCancellation)
      #expect(!synthetic.noiseSuppression)
      #expect(synthetic.autoGainControl)
      #expect(synthetic.echoCancellationMode == .software)
      #expect(synthetic.autoGainControlMode == .software)
      #expect(synthetic.noiseSuppressionMode == .software)
      let after = AudioCaptureOptions()
      #expect(before == after)
      #expect(after.echoCancellation)
      #expect(after.noiseSuppression)
      #expect(after.autoGainControl)
      #expect(after.echoCancellationMode == .automatic)
      #expect(after.autoGainControlMode == .automatic)
      #expect(after.noiseSuppressionMode == .automatic)
    }

    @Test
    func captureRetainsSilentInputClockAndReleasesOwnedNodes() throws {
      let engine = AVAudioEngine()
      let input = AVAudioMixerNode()
      let destination = AVAudioMixerNode()
      engine.attach(input)
      engine.attach(destination)
      let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
      let hooks = MarkerAudioEngine(
        probe: MediaAudioProbe(), frequencies: Array(repeating: 650, count: 12))
      #expect(
        hooks.engineWillConnectInput(
          engine, src: input, dst: destination, format: format, context: [:]) == 0)
      let clock = try #require(
        engine.inputConnectionPoint(for: destination, inputBus: 0)?.node as? AVAudioMixerNode)
      #expect(clock.outputVolume == 0)
      #expect(engine.inputConnectionPoint(for: clock, inputBus: 0)?.node === input)
      let source = try #require(
        engine.inputConnectionPoint(for: destination, inputBus: 1)?.node as? AVAudioSourceNode)
      #expect(!engine.isRunning)
      #expect(hooks.generatedSamples == 0)
      #expect(
        hooks.engineWillConnectInput(
          engine, src: input, dst: destination, format: format, context: [:]) == 0)
      #expect(source.engine == nil)
      #expect(clock.engine == nil)
      let replacementClock = try #require(
        engine.inputConnectionPoint(for: destination, inputBus: 0)?.node as? AVAudioMixerNode)
      let replacementSource = try #require(
        engine.inputConnectionPoint(for: destination, inputBus: 1)?.node as? AVAudioSourceNode)
      #expect(replacementClock.outputVolume == 0)
      #expect(engine.inputConnectionPoint(for: replacementClock, inputBus: 0)?.node === input)
      #expect(hooks.engineWillRelease(engine) == 0)
      #expect(replacementSource.engine == nil)
      #expect(replacementClock.engine == nil)
      #expect(engine.attachedNodes.count == 2)
    }

    @Test(arguments: [8000, 48000])
    func tonesV2CaptureMatchesPCM16Parity(rate: Int) {
      let frequencies: [Double] = [
        650, 950, 1350, 1850, 1850, 1850, 950, 1350, 650, 650, 1850, 1350,
      ]
      var bytes: [UInt8] = []
      for index in 0..<(rate * 72 / 100) {
        let sample = MarkerSignal.sample(Int64(index), rate: Double(rate), frequencies: frequencies)
        let pcm = UInt16(bitPattern: Int16(floor(Double(sample) * 32767 + 0.5)))
        bytes.append(UInt8(truncatingIfNeeded: pcm))
        bytes.append(UInt8(truncatingIfNeeded: pcm >> 8))
      }
      let hash = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
      let expected =
        rate == 8000
        ? "7305be4e1d4ba73d2f2f876869fa5cb27c12bb91450081452139f41262f7c003"
        : "82f79efb9f1b24a5c839cd500f5c9ad291ef5969348c3d68b775fcef6f8fa3b4"
      #expect(hash == expected)
    }

    @Test(arguments: [8000, 48000])
    func emissionCaptureMatchesPCM16Parity(rate: Int) {
      let frequencies: [Double] = [
        650, 950, 1350, 1850, 1850, 1850, 950, 1350, 650, 650, 1850, 1350,
      ]
      var bytes: [UInt8] = []
      for index in 0..<(rate * 102 / 100) {
        let sample = MarkerSignal.emissionSample(
          Int64(index), rate: Double(rate), frequencies: frequencies)
        let pcm = UInt16(bitPattern: Int16(floor(Double(sample) * 32767 + 0.5)))
        bytes.append(UInt8(truncatingIfNeeded: pcm))
        bytes.append(UInt8(truncatingIfNeeded: pcm >> 8))
      }
      let hash = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
      let expected =
        rate == 8000
        ? "e339576ee90e3d72ef65c7a5e44ab4a74345be472fdcd39b8f25072448a5fbab"
        : "0a79ca1399b4fc018584bcf8e90be7c476618fab47f903b9670ce1282eafbaa1"
      #expect(hash == expected)
    }

    @Test
    func diagnosticCapturePreservesChannelsAndStopsAtThreeSeconds() throws {
      let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
      buffer.frameLength = 48_000
      let samples = try #require(buffer.floatChannelData)
      for index in 0..<48_000 {
        samples[0][index] = 0
        samples[1][index] = 0.125
      }
      let probe = MediaAudioProbe()
      for _ in 0..<4 { probe.receive(buffer, at: .output) }
      let captured = probe.capture(.output)
      #expect(captured.sampleRate == 48_000)
      #expect(captured.channels.count == 2)
      #expect(captured.channels[0].count == 144_000)
      #expect(captured.channels[0].allSatisfy { $0 == 0 })
      #expect(captured.channels[1].allSatisfy { $0 == 0.125 })
      #expect(!captured.formatChanged)
      let changedFormat = try #require(
        AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
      let changed = try #require(AVAudioPCMBuffer(pcmFormat: changedFormat, frameCapacity: 1))
      changed.frameLength = 1
      changed.floatChannelData?[0][0] = 0
      probe.receive(changed, at: .output)
      #expect(probe.capture(.output).formatChanged)
      probe.beginWindow()
      #expect(probe.capture(.output).channels.isEmpty)
    }

    @Test(arguments: [false, true])
    func rightChannelLeakIsNotSilence(interleaved: Bool) throws {
      let format = try #require(
        AVAudioFormat(
          commonFormat: .pcmFormatFloat32,
          sampleRate: 48_000, channels: 2, interleaved: interleaved))
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
      buffer.frameLength = 480
      let samples = try #require(buffer.floatChannelData)
      for index in 0..<480 {
        if interleaved {
          samples[0][index * 2] = 0
          samples[0][index * 2 + 1] = 0.1
        } else {
          samples[0][index] = 0
          samples[1][index] = 0.1
        }
      }
      let probe = MediaAudioProbe()
      probe.installed(.output)
      probe.receive(buffer, at: .output)
      #expect(throws: MediaAudioProbe.Failure.audioLeaked(.output)) {
        try probe.expectSilence(.output)
      }
    }

    @Test
    func aStoppedTapCannotCoverASilentInterval() throws {
      let clock = TestClock()
      let measured = MediaAudioProbe(clock: clock)
      let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
      buffer.frameLength = 960
      let samples = try #require(buffer.floatChannelData?[0])
      for index in 0..<960 { samples[index] = 0 }
      measured.installed(.output)
      measured.beginWindow()
      measured.receive(buffer, at: .output)
      clock.advance(by: .seconds(1))
      #expect(throws: MediaAudioProbe.Failure.incompleteWindow(.output)) {
        try measured.expectSilence(.output, for: .seconds(1))
      }
      measured.beginWindow()
      for _ in 0..<50 {
        measured.receive(buffer, at: .output)
        clock.advance(by: .milliseconds(20))
      }
      try measured.expectSilence(.output, for: .seconds(1))
    }
    @Test(arguments: [MediaAudioProbe.Stage.decoded, .output])
    func missingTapCannotPassSilence(_ stage: MediaAudioProbe.Stage) {
      let probe = MediaAudioProbe()
      #expect(throws: MediaAudioProbe.Failure.missingTap(stage)) {
        try probe.expectSilence(stage)
      }
      probe.installed(stage)
      #expect(throws: MediaAudioProbe.Failure.noFrames(stage)) {
        try probe.expectSilence(stage)
      }
    }

    @Test
    func silenceNeedsRealCallbacksAndNonzeroAudioFails() throws {
      let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
      buffer.frameLength = 480
      let samples = try #require(buffer.floatChannelData?[0])
      let probe = MediaAudioProbe()
      probe.installed(.output)
      for index in 0..<480 { samples[index] = 0 }
      probe.receive(buffer, at: .output)
      try probe.expectSilence(.output)
      #expect(throws: MediaAudioProbe.Failure.signalMissing(.output)) {
        try probe.expectAudio(.output)
      }
      probe.beginWindow()
      #expect(throws: MediaAudioProbe.Failure.noFrames(.output)) {
        try probe.expectSilence(.output)
      }
      for index in 0..<480 { samples[index] = 0.1 }
      probe.receive(buffer, at: .output)
      try probe.expectAudio(.output)
      #expect(throws: MediaAudioProbe.Failure.audioLeaked(.output)) {
        try probe.expectSilence(.output)
      }
    }
  }
#endif
