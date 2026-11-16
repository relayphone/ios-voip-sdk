#if os(iOS)
  import AVFAudio
  import Foundation
  import Testing
  import Synchronization
  import VoIPCore

  @testable import VoIPAudio

  @Suite("System video mode", .serialized) @VoIPActor
  struct SystemVideoModeTests {
    @Test func runningOutputMeasuresCallbackGapsAcrossModeChanges() async throws {
      let audio = AVAudioSession.sharedInstance()
      let previous = (audio.category, audio.mode, audio.categoryOptions)
      let engine = AVAudioEngine()
      defer {
        engine.stop()
        try? audio.setActive(false)
        try? audio.setCategory(previous.0, mode: previous.1, options: previous.2)
      }
      let session = SystemSession()
      try session.setCategory(options: [.allowBluetoothHFP])
      // Only this test activates its own output. The SDK's mode changes never do.
      try audio.setActive(true)
      let format = engine.outputNode.inputFormat(forBus: 0)
      #expect(format.sampleRate > 0)
      let probe = ModeCallbackProbe()
      let source = modeSource(format: format, probe: probe)
      engine.attach(source)
      engine.connect(source, to: engine.mainMixerNode, format: format)
      try engine.start()
      try await Task.sleep(for: .milliseconds(500))
      let voiceCount = probe.count
      try session.setVideoMode(true)
      try await Task.sleep(for: .milliseconds(500))
      let videoCount = probe.count
      try session.setVideoMode(false)
      try await Task.sleep(for: .milliseconds(500))
      #expect(engine.isRunning)
      #expect(voiceCount > 0 && videoCount > voiceCount && probe.count > videoCount)
      print(
        "Video mode PCM callback maximum interval: \(probe.maximumGap); callbacks: \(probe.count)")
    }

    @Test func modeChangesPreserveExplicitCategoryOptionsWithoutActivation() throws {
      let audio = AVAudioSession.sharedInstance()
      let previous = (audio.category, audio.mode, audio.categoryOptions)
      defer { try? audio.setCategory(previous.0, mode: previous.1, options: previous.2) }
      let session = SystemSession()
      try session.setCategory(options: [.allowBluetoothHFP])
      let options = audio.categoryOptions
      try session.setVideoMode(true)
      #expect(audio.mode == .videoChat)
      #expect(audio.categoryOptions == options)
      #expect(!audio.categoryOptions.contains(.defaultToSpeaker))
      try session.setVideoMode(false)
      #expect(audio.mode == .voiceChat)
      #expect(audio.categoryOptions == options)
    }
  }
  // Core Audio invokes this block on its own render thread, outside VoIPActor.
  private func modeSource(format: AVAudioFormat, probe: ModeCallbackProbe) -> AVAudioSourceNode {
    let sampleRate = Float(format.sampleRate)
    return AVAudioSourceNode(format: format) { _, _, frames, buffers in
      let start = probe.record(frames: frames)
      for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
        guard let data = buffer.mData else { continue }
        let values = data.assumingMemoryBound(to: Float.self)
        for index in 0..<Int(frames) {
          values[index] = 0.001 * sin(Float(start + Int64(index)) * 2 * .pi * 440 / sampleRate)
        }
      }
      return 0
    }
  }

  private final class ModeCallbackProbe: Sendable {
    private struct State {
      var times: [ContinuousClock.Instant] = []
      var frames: Int64 = 0
    }
    private let state = Mutex(State())
    func record(frames: UInt32) -> Int64 {
      state.withLock {
        if $0.times.count < 512 { $0.times.append(.now) }
        let start = $0.frames
        $0.frames += Int64(frames)
        return start
      }
    }
    var count: Int { state.withLock { $0.times.count } }
    var maximumGap: Duration {
      state.withLock { value in
        zip(value.times, value.times.dropFirst()).map { $0.duration(to: $1) }.max() ?? .zero
      }
    }
  }
#endif
