import Foundation
import Testing

@testable import VoIPMediaTesting

struct CallbackEvidenceTests {
  @Test func originalMeasurementsKeepSamplePositionsAndIndependentSnapshots() throws {
    var history = MediaPCMCallbackEvidence()
    history.record(
      atSeconds: 2, frameCount: 480, sampleRate: 48000, channels: 2, energy: 37.5, peak: 0.25)
    let first = history
    history.record(
      atSeconds: 2.01, frameCount: 480, sampleRate: 48000, channels: 2, energy: 0, peak: 0)
    #expect(first.frames.count == 1)
    #expect(history.frames.map(\.sampleOffset) == [0, 480])
    #expect(history.frames.map(\.atSeconds) == [2, 2.01])
    #expect(history.frames.map(\.energy) == [37.5, 0])
    #expect(history.frames.map(\.peak) == [0.25, 0])
    #expect(
      history.frames.allSatisfy {
        $0.frameCount == 480 && $0.channels == 2 && $0.sampleRate == 48000
      })
    let decoded = try JSONDecoder().decode(
      MediaPCMCallbackEvidence.self, from: JSONEncoder().encode(history))
    #expect(decoded.frames.map(\.sampleOffset) == [0, 480])
    #expect(decoded.frames.map(\.peak) == [0.25, 0])
    #expect(decoded.droppedFrames == 0)
  }

  @Test func overflowRemainsExplicitAndDoesNotOverwriteOldEvidence() {
    var history = MediaPCMCallbackEvidence()
    for index in 0..<8196 {
      history.record(
        atSeconds: Double(index), frameCount: 1, sampleRate: 48000, channels: 1, energy: 0, peak: 0)
    }
    #expect(history.frames.count == 8192)
    #expect(history.droppedFrames == 4)
    #expect(history.frames.first?.sampleOffset == 0)
    #expect(history.frames.last?.sampleOffset == 8191)
    history = MediaPCMCallbackEvidence()
    history.record(
      atSeconds: 10, frameCount: 480, sampleRate: 48000, channels: 1, energy: 0, peak: 0)
    #expect(history.frames.count == 1)
    #expect(history.frames[0].sampleOffset == 0)
    #expect(history.droppedFrames == 0)
  }
}
