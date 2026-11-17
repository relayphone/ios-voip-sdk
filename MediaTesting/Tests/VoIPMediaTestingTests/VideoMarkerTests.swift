import Foundation
import Testing
import VoIPTesting

@testable import VoIPMediaTesting

@Suite("Synthetic video evidence")
struct VideoMarkerTests {
  private let fixture = UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!
  private func marker(counter: UInt32 = 0, epoch: UInt32 = 7, at: UInt64 = 0) throws -> VideoMarker
  {
    try VideoMarker(
      fixture: fixture, direction: .uplink, epoch: epoch, counter: counter, sourceTimeUs: at)
  }
  private func receive(_ marker: VideoMarker, into evidence: VideoCalibration) throws {
    evidence.receive(
      luma: try marker.luma(width: 160, height: 120), width: 160, height: 120, stride: 160)
  }
  @Test(arguments: [(160, 120), (320, 240)])
  func deterministicPixelRoundTripWithPaddingAndLoss(dimensions: (Int, Int)) throws {
    let (width, height) = dimensions
    let original = try marker(counter: .max, at: 9_007_199_254_740_991)
    let pixels = try original.luma(width: width, height: height)
    #expect(pixels == (try original.luma(width: width, height: height)))
    let stride = width + 16
    var padded = [UInt8](repeating: 99, count: stride * height)
    for row in 0..<height {
      for column in 0..<width {
        let value = pixels[row * width + column]
        padded[row * stride + column] = value < 100 ? value + 20 : value > 160 ? value - 20 : value
      }
    }
    #expect(
      try VideoMarker.decode(luma: padded, width: width, height: height, stride: stride) == original
    )
    let wire = try JSONEncoder().encode(original)
    #expect(try JSONDecoder().decode(VideoMarker.self, from: wire) == original)
  }
  @Test func corruptGridAndUnknownDimensionsCannotDecode() throws {
    var pixels = try marker().luma(width: 160, height: 120)
    for y in 0..<6 { for x in 8..<14 { pixels[y * 160 + x] = 235 } }
    #expect(throws: VideoMarker.Failure.self) {
      try VideoMarker.decode(luma: pixels, width: 160, height: 120, stride: 160)
    }
    #expect(throws: VideoMarker.Failure.dimensions) { try marker().luma(width: 10, height: 10) }
    #expect(throws: VideoMarker.Failure.dimensions) {
      try VideoMarker.decode(luma: [], width: 320, height: 240, stride: .max)
    }
    #expect(throws: VideoMarker.Failure.time) { try marker(at: .max) }
  }
  @Test func stoppedLedgerRejectsGenerationAndRetainsFinalCounterAtEqualTimestamp() throws {
    var ledger = VideoSourceLedger(clockID: UUID(), fixture: fixture, direction: .uplink, epoch: 7)
    let first = try ledger.generate(atUs: 100)
    try ledger.stop(atUs: 100)
    #expect(ledger.finalCounter == first.counter)
    #expect(ledger.stoppedAtUs == 100)
    #expect(throws: VideoMarker.Failure.stopped) { try ledger.generate(atUs: 100) }
    try ledger.stop(atUs: 200)
    #expect(ledger.stoppedAtUs == 100)
    #expect(ledger.isAfterBoundary(try marker(counter: 1, at: 100)))
    #expect(!ledger.isAfterBoundary(first))
  }
  @Test func realPixelArrivalsMeasureLatencyWindowsAndDrainWithoutHidingLateFrames() throws {
    let clock = TestClock()
    let shared = MediaObservationClock(clock: TestClock())
    let measured = MediaObservationClock(clock: clock)
    let evidence = VideoCalibration(observationClock: measured)
    var ledger = VideoSourceLedger(
      clockID: measured.id, fixture: fixture, direction: .uplink, epoch: 7)
    let anchor = try ledger.anchor(atUs: 0)
    let first = try ledger.generate(atUs: 0)
    evidence.record(.receiverAttached)
    clock.advance(by: .milliseconds(100))
    try receive(first, into: evidence)
    clock.advance(by: .milliseconds(800))
    let last = try ledger.generate(atUs: 900_000)
    clock.advance(by: .milliseconds(100))
    try ledger.stop(atUs: 1_000_000)
    evidence.record(.publicationUnpublished)
    clock.advance(by: .milliseconds(100))
    try receive(last, into: evidence)
    clock.advance(by: .milliseconds(100))
    try receive(try marker(counter: 2, at: 1_000_001), into: evidence)
    evidence.record(.receiverHeartbeat)
    let report = try evidence.receipt(source: ledger, anchor: anchor)
    #expect(report.firstFrameLatencyUs == 100_000)
    #expect(report.maximumPipelineResidenceUs == 200_000)
    #expect(report.preBoundaryDrainUs == 100_000)
    #expect(report.postBoundaryFrames == 1)
    #expect(report.unmatchedFrames == 1)
    #expect(report.arrivals.count == 3)
    #expect(report.source.finalCounter == 1)
    #expect(report.resourcesAtEnd != nil)
    #expect(report.queueHighWaterMark == 1)
    #expect(!report.overflow)
    #expect(throws: VideoCalibration.Failure.clockMismatch) {
      try VideoCalibration(observationClock: shared).receipt(source: ledger, anchor: anchor)
    }
    let data = try JSONEncoder().encode(report)
    struct Wire: Decodable { let postBoundaryFrames: Int }
    #expect(try JSONDecoder().decode(Wire.self, from: data).postBoundaryFrames == 1)
  }
  @Test func staleCorruptAndFrozenControlsRemainVisibleAndCannotInflateFPS() throws {
    let clock = TestClock()
    let shared = MediaObservationClock(clock: clock)
    let evidence = VideoCalibration(observationClock: shared)
    var ledger = VideoSourceLedger(
      clockID: shared.id, fixture: fixture, direction: .uplink, epoch: 7)
    let anchor = try ledger.anchor(atUs: 0)
    let valid = try ledger.generate(atUs: 0)
    evidence.record(.receiverAttached)
    for _ in 0..<10 {
      clock.advance(by: .milliseconds(100))
      try receive(valid, into: evidence)
    }
    try receive(try marker(epoch: 8), into: evidence)
    evidence.receive(
      luma: [UInt8](repeating: 128, count: 160 * 120), width: 160, height: 120, stride: 160)
    let report = try evidence.receipt(source: ledger, anchor: anchor)
    #expect(report.duplicateFrames == 9)
    #expect(report.unmatchedFrames == 1)
    #expect(report.corruptFrames == 1)
    #expect(report.windows.map(\.uniqueFPS) == [1])
    #expect(report.maximumGapUs == 900_000)
    #expect(report.preBoundaryDrainUs == nil)
  }
  @Test func evidenceAndLedgerCapacityAreBoundedWithExplicitFailure() throws {
    let clock = TestClock()
    let shared = MediaObservationClock(clock: TestClock())
    var ledger = VideoSourceLedger(
      clockID: shared.id, fixture: fixture, direction: .uplink, epoch: 7)
    for value in 0..<4096 { _ = try ledger.generate(atUs: UInt64(value)) }
    #expect(throws: VideoMarker.Failure.exhausted) { try ledger.generate(atUs: 4096) }
    let evidenceClock = MediaObservationClock(clock: clock)
    let evidence = VideoCalibration(observationClock: evidenceClock)
    let empty = VideoSourceLedger(
      clockID: evidenceClock.id, fixture: fixture, direction: .uplink, epoch: 7)
    for _ in 0..<4097 { evidence.receive(luma: [], width: 0, height: 0, stride: 0) }
    let report = try evidence.receipt(source: empty, anchor: empty.anchor(atUs: 0))
    #expect(report.arrivals.count == 4096)
    #expect(report.overflow)
    #expect(report.firstFrameLatencyUs == nil)
  }
  @Test func unavailableOutsideSimulatorDebug() {
    #if DEBUG && os(iOS) && targetEnvironment(simulator)
      #expect(MediaVideoSupport.canCapture)
    #else
      #expect(!MediaVideoSupport.canCapture)
    #endif
  }
  @Test func longCaptureSkipsElapsedDeadlinesInsteadOfBursting() throws {
    let clock = TestClock()
    let start = clock.now
    var schedule = VideoFrameSchedule(next: start)
    clock.advance(by: .milliseconds(190))
    #expect(schedule.completed(at: clock.now) == 1)
    #expect(schedule.next == start.advanced(by: .milliseconds(200)))
    #expect(schedule.wake(after: clock.now) == start.advanced(by: .milliseconds(290)))
    var ledger = VideoSourceLedger(clockID: UUID(), fixture: fixture, direction: .uplink, epoch: 7)
    _ = try ledger.generate(atUs: 0)
    try ledger.skipTick()
    #expect(try ledger.generate(atUs: 200_000).counter == 2)
    #expect(ledger.skippedTicks == 1)
  }
  @Test func delayedWakeNeverCompressesTheFollowingFrameInterval() {
    let clock = TestClock()
    let start = clock.now
    var schedule = VideoFrameSchedule(next: start.advanced(by: .milliseconds(100)))
    clock.advance(by: .milliseconds(190))
    #expect(schedule.completed(at: clock.now) == 0)
    #expect(schedule.wake(after: clock.now) == start.advanced(by: .milliseconds(290)))
  }
  @Test func seedAtTheSameTimestampCannotSatisfyTheNewPhase() throws {
    let clock = TestClock()
    let shared = MediaObservationClock(clock: TestClock())
    let measured = MediaObservationClock(clock: clock)
    var ledger = VideoSourceLedger(
      clockID: measured.id, fixture: fixture, direction: .uplink, epoch: 7)
    let seed = try ledger.generate(atUs: 0)
    let anchor = try ledger.anchor(atUs: 0)
    let evidence = VideoCalibration(observationClock: measured)
    try receive(seed, into: evidence)
    #expect(try evidence.receipt(source: ledger, anchor: anchor).firstFrameLatencyUs == nil)
    let fresh = try ledger.generate(atUs: 0)
    try receive(fresh, into: evidence)
    #expect(try evidence.receipt(source: ledger, anchor: anchor).firstFrameLatencyUs == 0)
    #expect(shared.id != measured.id)
  }
  @Test func wireTimestampsCannotBypassExactIntegerValidation() throws {
    let json = """
      {"fixture":"01234567-89ab-cdef-0123-456789abcdef","direction":0,"epoch":7,"counter":0,"sourceTimeUs":9007199254740992}
      """
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(VideoMarker.self, from: Data(json.utf8))
    }
  }
  @Test func unidentifiedPostStopPixelsCannotBecomeAZeroDrainMeasurement() throws {
    let clock = TestClock()
    let measured = MediaObservationClock(clock: TestClock())
    let shared = MediaObservationClock(clock: clock)
    let evidence = VideoCalibration(observationClock: shared)
    var ledger = VideoSourceLedger(
      clockID: shared.id, fixture: fixture, direction: .uplink, epoch: 7)
    let anchor = try ledger.anchor(atUs: 0)
    _ = try ledger.generate(atUs: 0)
    try ledger.stop(atUs: 0)
    clock.advance(by: .milliseconds(10))
    evidence.receive(
      luma: [UInt8](repeating: 16, count: 160 * 120), width: 160, height: 120, stride: 160)
    let report = try evidence.receipt(source: ledger, anchor: anchor)
    #expect(report.ambiguousBoundaryFrames == 1)
    #expect(report.postBoundaryFrames == 0)
    #expect(report.preBoundaryDrainUs == nil)
    #expect(report.firstCorruptFrame?.luma.count == 160 * 120)
    #expect(measured.id != shared.id)
  }
}
