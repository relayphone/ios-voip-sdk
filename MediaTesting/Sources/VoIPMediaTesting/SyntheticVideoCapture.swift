/// Compile-time availability of the optional synthetic camera implementation.
public enum MediaVideoSupport {
  /// True only in a DEBUG iOS simulator build; ordinary builds contain no capture implementation.
  public static var canCapture: Bool {
    #if DEBUG && os(iOS) && targetEnvironment(simulator)
      true
    #else
      false
    #endif
  }
}

#if DEBUG && os(iOS) && targetEnvironment(simulator)
  import CoreVideo
  public import Foundation
  #if SWIFT_PACKAGE
    public import LiveKit
  #else
    public import LiveKitClient
  #endif

  /// An app-owned test source. It never opens a camera, requests permission or publishes a track.
  public actor SyntheticVideoCapture {
    /// Owned local camera track, supplied to the app's ordinary publication path.
    public let track: LocalVideoTrack
    private let capturer: BufferCapturer
    private let clock: MediaObservationClock
    private var ledger: VideoSourceLedger
    private let width: Int, height: Int
    private var pool: CVPixelBufferPool?
    private var running = false
    private var pacingSleep: Task<Void, any Error>?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    /// Allocation or unsupported-capturer failure, with no fallback to a physical camera.
    public enum Failure: Error { case capturer, pixelBuffer, duration, alreadyRunning }
    private init(
      track: LocalVideoTrack, capturer: BufferCapturer, clock: MediaObservationClock,
      ledger: VideoSourceLedger, width: Int, height: Int
    ) {
      self.track = track
      self.capturer = capturer
      self.clock = clock
      self.ledger = ledger
      self.width = width
      self.height = height
    }
    /// Creates and seeds a 10 fps buffer track; only the approved calibration profiles are accepted.
    public static func make(
      fixture: UUID, direction: VideoMarker.Direction, epoch: UInt32,
      observationClock: MediaObservationClock, width: Int = 320, height: Int = 240
    ) async throws -> SyntheticVideoCapture {
      guard (width == 320 && height == 240) || (width == 160 && height == 120) else {
        throw VideoMarker.Failure.dimensions
      }
      let track = await LocalVideoTrack.createBufferTrack(
        name: "synthetic-camera", source: .camera,
        options: BufferCaptureOptions(
          dimensions: Dimensions(width: Int32(width), height: Int32(height)), fps: 10))
      guard let capturer = track.capturer as? BufferCapturer else { throw Failure.capturer }
      let source = SyntheticVideoCapture(
        track: track, capturer: capturer, clock: observationClock,
        ledger: VideoSourceLedger(
          clockID: observationClock.id, fixture: fixture, direction: direction, epoch: epoch),
        width: width, height: height)
      try await source.captureFrame()
      return source
    }
    /// Generates and submits one original frame in the same actor turn as the ledger update.
    /// Hold should gate publication, not call this method less frequently.
    @discardableResult public func captureFrame() throws -> VideoMarker {
      let marker = try ledger.generate(atUs: UInt64(max(0, clock.milliseconds * 1000)))
      var submitted = false
      defer { if !submitted { ledger.rejectSubmission() } }
      let pixels = try marker.luma(width: width, height: height)
      if pool == nil {
        let attributes =
          [
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
          ] as CFDictionary
        guard CVPixelBufferPoolCreate(nil, nil, attributes, &pool) == kCVReturnSuccess else {
          throw Failure.pixelBuffer
        }
      }
      var buffer: CVPixelBuffer?
      guard let pool,
        CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
          nil, pool,
          [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary, &buffer)
          == kCVReturnSuccess, let buffer
      else { throw Failure.pixelBuffer }
      CVPixelBufferLockBaseAddress(buffer, [])
      defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
      guard let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
        let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
      else { throw Failure.pixelBuffer }
      let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
      let destination = y.assumingMemoryBound(to: UInt8.self)
      for row in 0..<height {
        for column in 0..<width {
          destination[row * stride + column] = pixels[row * width + column]
        }
      }
      uv.initializeMemory(
        as: UInt8.self, repeating: 128,
        count: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
          * CVPixelBufferGetHeightOfPlane(buffer, 1))
      capturer.capture(buffer, timeStampNs: Int64(marker.sourceTimeUs) * 1000)
      submitted = true
      return marker
    }
    /// Structured, cancellable pacing with a hard duration and no catch-up bursts.
    public func run<C: Clock<Duration>>(clock pacingClock: C, duration: Duration) async throws {
      guard duration > .zero, duration <= .seconds(180) else { throw Failure.duration }
      guard !running else { throw Failure.alreadyRunning }
      guard ledger.stoppedAtUs == nil else { throw VideoMarker.Failure.stopped }
      running = true
      ledger.pacingTaskJoined = false
      defer {
        running = false
        ledger.pacingTaskJoined = true
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
      }
      let end = pacingClock.now.advanced(by: duration)
      var schedule = VideoFrameSchedule(next: pacingClock.now)
      while pacingClock.now < end {
        if ledger.stoppedAtUs != nil { return }
        try Task.checkCancellation()
        while schedule.next.advanced(by: .milliseconds(100)) <= pacingClock.now {
          try ledger.skipTick()
          schedule.next = schedule.next.advanced(by: .milliseconds(100))
        }
        try captureFrame()
        for _ in 0..<schedule.completed(at: pacingClock.now) { try ledger.skipTick() }
        let wake = min(end, schedule.wake(after: pacingClock.now))
        let sleep = Task { try await pacingClock.sleep(until: wake, tolerance: .zero) }
        pacingSleep = sleep
        do {
          try await withTaskCancellationHandler {
            try await sleep.value
          } onCancel: {
            sleep.cancel()
          }
          pacingSleep = nil
        } catch {
          pacingSleep = nil
          if ledger.stoppedAtUs != nil { return }
          throw error
        }
      }
    }
    /// Atomically freezes generation, then joins pacing before returning the final receipt.
    /// The app separately records the actual unpublish/mute and keeps the receiver healthy.
    public func stop() async throws(VideoMarker.Failure) -> VideoSourceLedger {
      try ledger.stop(atUs: UInt64(max(0, clock.milliseconds * 1000)))
      pacingSleep?.cancel()
      if running {
        await withCheckedContinuation { stopWaiters.append($0) }
      }
      return ledger
    }
    /// Original bounded ledger, including the seed and any capture attempts that failed after generation.
    public func snapshot() -> VideoSourceLedger { ledger }
    /// Captures time and last generated counter together before arming a measurement phase.
    public func anchor() throws(VideoMarker.Failure) -> VideoSourceLedger.Anchor {
      try ledger.anchor(atUs: UInt64(max(0, clock.milliseconds * 1000)))
    }
  }

  /// Retain this headless observer for the entire measurement and drain interval.
  public final class SyntheticVideoReceiver: VideoRenderer {
    /// Disable view-dependent subscription adaptation for this headless test observer.
    @MainActor public var isAdaptiveStreamEnabled: Bool { false }
    /// No UI surface participates in subscription decisions.
    @MainActor public var adaptiveStreamSize: CGSize { .zero }
    private let calibration: VideoCalibration
    /// Uses an existing recorder on the same observation clock as the source.
    public init(calibration: VideoCalibration) { self.calibration = calibration }
    /// Observes actual decoded luma; unsupported conversion is recorded as a corrupt arrival.
    public func render(frame: VideoFrame) {
      calibration.receiveDecoded {
        let type: VideoImageProvenance.BufferType =
          frame.buffer is I420VideoBuffer
          ? .i420
          : frame.buffer is CVPixelVideoBuffer ? .pixelBuffer : .unsupported
        guard let buffer = frame.toI420() else {
          return .decode(
            luma: [], width: Int(frame.dimensions.width), height: Int(frame.dimensions.height),
            stride: 0, bufferType: type, mediaTimestampNs: frame.timeStampNs,
            rtpTimestamp: frame.rtpTimestamp)
        }
        return buffer.withUnsafePlanes { planes in
          let width = Int(planes.width)
          let height = Int(planes.height)
          let stride = Int(planes.strideY)
          let cw = Int(planes.chromaWidth)
          let ch = Int(planes.chromaHeight)
          let su = Int(planes.strideU)
          let sv = Int(planes.strideV)
          guard width > 0, width <= 1920, height > 0, height <= 1080,
            stride >= width, stride <= 16384, cw == (width + 1) / 2,
            ch == (height + 1) / 2, su >= cw, su <= 16384, sv >= cw, sv <= 16384
          else {
            return .decode(
              luma: [], width: width, height: height, stride: stride, bufferType: type,
              mediaTimestampNs: frame.timeStampNs, rtpTimestamp: frame.rtpTimestamp)
          }
          return .decode(
            luma: Array(UnsafeBufferPointer(start: planes.dataY, count: stride * height)),
            width: width, height: height, stride: stride,
            u: .init(
              bytes: Array(UnsafeBufferPointer(start: planes.dataU, count: su * ch)),
              width: cw, height: ch, stride: su),
            v: .init(
              bytes: Array(UnsafeBufferPointer(start: planes.dataV, count: sv * ch)),
              width: cw, height: ch, stride: sv),
            bufferType: type, mediaTimestampNs: frame.timeStampNs, rtpTimestamp: frame.rtpTimestamp)
        }
      }
    }
  }
#endif

struct VideoFrameSchedule<I: InstantProtocol> where I.Duration == Duration {
  var next: I
  func wake(after completion: I) -> I {
    max(next, completion.advanced(by: .milliseconds(100)))
  }
  mutating func completed(at now: I) -> Int {
    next = next.advanced(by: .milliseconds(100))
    var skipped = 0
    while next <= now {
      next = next.advanced(by: .milliseconds(100))
      skipped += 1
    }
    return skipped
  }
}
