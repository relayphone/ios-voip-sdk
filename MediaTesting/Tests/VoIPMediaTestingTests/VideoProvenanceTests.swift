import Foundation
import Testing
import VoIPTesting

@testable import VoIPMediaTesting

@Suite("Decoded video provenance")
struct VideoProvenanceTests {
  @Test func emptyProducerStopHasAnExplicitNullCounterAndFrozenEpoch() throws {
    var ledger = VideoSourceLedger(clockID: UUID(), fixture: UUID(), direction: .uplink, epoch: 3)
    try ledger.stop(atUs: 0)
    #expect(throws: VideoMarker.Failure.stopped) { try ledger.generate(atUs: 0) }
    try ledger.stop(atUs: 100)
    #expect(ledger.finalEpoch == 3)
    #expect(ledger.stoppedAtUs == 0)
    #expect(ledger.postStopCaptureRejects == 1)
    struct Wire: Decodable {
      enum CodingKeys: String, CodingKey { case finalCounter }
      let explicitNull: Bool
      init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        explicitNull =
          try container.contains(.finalCounter) && container.decodeNil(forKey: .finalCounter)
      }
    }
    #expect(try JSONDecoder().decode(Wire.self, from: JSONEncoder().encode(ledger)).explicitNull)
  }
  private func classification(
    _ bytes: [UInt8], width: Int = 8, height: Int = 8, stride: Int = 8,
    u: VideoImageProvenance.Plane? = nil, v: VideoImageProvenance.Plane? = nil
  ) -> VideoImageProvenance.Classification {
    VideoCalibration.Image.decode(
      luma: bytes, width: width, height: height, stride: stride, u: u, v: v
    ).provenance.classification
  }

  @Test(arguments: [UInt8(0), 16, 128, 235, 255])
  func uniformContentIsIndependentOfBrightness(value: UInt8) {
    #expect(classification([UInt8](repeating: value, count: 64)) == .contentFree)
  }
  @Test func scansTheLastSampleAndIgnoresPadding() {
    var bytes = [UInt8](repeating: 100, count: 64)
    bytes[0] = 98
    bytes[63] = 102
    #expect(classification(bytes) == .contentFree)
    bytes[63] = 103
    #expect(classification(bytes) == .ambiguous)
    var padded = [UInt8](repeating: 255, count: 80)
    for row in 0..<8 { for col in 0..<8 { padded[row * 10 + col] = 100 } }
    #expect(classification(padded, stride: 10) == .contentFree)
  }
  @Test func sourceGeometryPartialAndInvalidPlanesStayAmbiguous() {
    for (w, h) in [(160, 120), (320, 240)] {
      #expect(
        classification([UInt8](repeating: 16, count: w * h), width: w, height: h, stride: w)
          == .ambiguous)
    }
    #expect(classification([UInt8](repeating: 16, count: 63)) == .ambiguous)
    #expect(classification([], width: Int.max, height: Int.max, stride: Int.max) == .ambiguous)
    let good = VideoImageProvenance.Plane(
      bytes: [UInt8](repeating: 128, count: 16), width: 4, height: 4, stride: 4)
    let partial = VideoImageProvenance.Plane(bytes: [128], width: 4, height: 4, stride: 4)
    var varied = [UInt8](repeating: 128, count: 16)
    varied[15] = 200
    let bad = VideoImageProvenance.Plane(bytes: varied, width: 4, height: 4, stride: 4)
    let y = [UInt8](repeating: 16, count: 64)
    #expect(classification(y, u: good, v: good) == .contentFree)
    #expect(classification(y, u: good) == .ambiguous)
    #expect(classification(y, u: partial, v: good) == .ambiguous)
    #expect(classification(y, u: good, v: bad) == .ambiguous)
  }
  @Test func contentFreeCallbacksNeverSatisfySourceMetricsAndDoNotInvalidateIdentifiedDrain() throws
  {
    let clock = TestClock()
    let shared = MediaObservationClock(clock: clock)
    let evidence = VideoCalibration(observationClock: shared)
    var ledger = VideoSourceLedger(
      clockID: shared.id, fixture: UUID(), direction: .uplink, epoch: 9)
    let anchor = try ledger.anchor(atUs: 0)
    let marker = try ledger.generate(atUs: 0)
    evidence.record(.receiverAttached)
    evidence.receive(luma: [UInt8](repeating: 235, count: 64), width: 8, height: 8, stride: 8)
    clock.advance(by: .seconds(1))
    try ledger.stop(atUs: 1_000_000)
    clock.advance(by: .milliseconds(100))
    evidence.receive(
      luma: try marker.luma(width: 160, height: 120), width: 160, height: 120, stride: 160)
    evidence.receiveDecoded {
      .decode(
        luma: [UInt8](repeating: 16, count: 64), width: 8, height: 8, stride: 8,
        bufferType: .i420, mediaTimestampNs: 42, rtpTimestamp: 43)
    }
    let report = try evidence.receipt(source: ledger, anchor: anchor)
    #expect(report.contentFreeFrames == 2)
    #expect(report.corruptFrames == 0)
    #expect(report.ambiguousBoundaryFrames == 0)
    #expect(report.preBoundaryDrainUs == 100_000)
    #expect(report.firstFrameLatencyUs == nil)
    #expect(report.windows.map(\.uniqueFPS) == [0])
    #expect(report.maximumGapUs == 1_000_000)
    #expect(report.arrivals.count == 3)
    #expect(report.arrivals.last?.provenance.mediaTimestampNs == 42)
    #expect(report.arrivals.last?.provenance.rtpTimestamp == 43)
    #expect(report.arrivals.last?.provenance.y.sample.count == 16)
    struct Wire: Decodable {
      struct Source: Decodable {
        let finalCounter: UInt32
        let finalEpoch: UInt32
      }
      let source: Source
    }
    let wire = try JSONDecoder().decode(Wire.self, from: JSONEncoder().encode(report))
    #expect(wire.source.finalCounter == marker.counter)
    #expect(wire.source.finalEpoch == 9)
  }
  @Test func postBoundaryRealImageWithUnreadableMarkerStillFails() throws {
    let shared = MediaObservationClock(clock: TestClock())
    let evidence = VideoCalibration(observationClock: shared)
    var ledger = VideoSourceLedger(
      clockID: shared.id, fixture: UUID(), direction: .uplink, epoch: 1)
    let anchor = try ledger.anchor(atUs: 0)
    let marker = try ledger.generate(atUs: 0)
    try ledger.stop(atUs: 0)
    var pixels = try marker.luma(width: 160, height: 120)
    // Destroy the marker header while retaining the generated real image's varying pixels.
    for row in 0..<8 { for col in 0..<16 { pixels[row * 160 + col] = 128 } }
    evidence.receive(luma: pixels, width: 160, height: 120, stride: 160)
    let report = try evidence.receipt(source: ledger, anchor: anchor)
    #expect(report.contentFreeFrames == 0)
    #expect(report.corruptFrames == 1)
    #expect(report.ambiguousBoundaryFrames == 1)
    #expect(report.preBoundaryDrainUs == nil)
  }
}

extension VideoProvenanceTests {
  @Test func remoteObservationPreservesPixelsWithoutALocalSourceClock() throws {
    let clock = MediaObservationClock()
    let recorder = VideoCalibration(observationClock: clock)
    let marker = try VideoMarker(
      fixture: UUID(), direction: .downlink, epoch: 4, counter: 9, sourceTimeUs: 7)
    recorder.record(.receiverAttached)
    recorder.receive(
      luma: try marker.luma(width: 160, height: 120), width: 160, height: 120, stride: 160)
    recorder.receive(luma: [], width: 160, height: 120, stride: 0)
    recorder.record(.receiverHeartbeat)
    let observed = recorder.observation()
    #expect(observed.clockID == clock.id)
    #expect(observed.arrivals.first?.marker == marker)
    #expect(observed.arrivals.last?.provenance.classification == .ambiguous)
    #expect(observed.arrivals.count == 2)
    #expect(observed.arrivals.allSatisfy { $0.atUs <= observed.observedAtUs })
    #expect(observed.lifecycle.map(\.kind) == [.receiverAttached, .receiverHeartbeat])
    #expect(!observed.overflow)
    #expect(observed.queueHighWaterMark == 1)
  }
  @Test func remoteObservationRejectsCallbackOverflowAndInFlightDecoding() {
    let recorder = VideoCalibration(observationClock: MediaObservationClock())
    recorder.receiveDecoded {
      let inFlight = recorder.observation()
      #expect(inFlight.overflow)
      #expect(inFlight.pendingDecodes == 1)
      return .decode(luma: [], width: 1, height: 1, stride: 0)
    }
    let complete = recorder.observation()
    #expect(complete.arrivals.count == 1)
    #expect(!complete.overflow)
    #expect(complete.pendingDecodes == 0)
    for _ in 0..<4096 { recorder.receive(luma: [], width: 1, height: 1, stride: 0) }
    let overflow = recorder.observation()
    #expect(overflow.arrivals.count == 4096)
    #expect(overflow.overflow)
    #expect(overflow.pendingDecodes == 0)
  }
}
