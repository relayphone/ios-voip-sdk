#if DEBUG && os(iOS) && targetEnvironment(simulator)
  import CoreVideo
  import Foundation
  import LiveKit
  import Testing
  import VoIPTesting

  @testable import VoIPMediaTesting

  @Suite("Simulator buffer camera", .serialized)
  struct VideoCaptureTests {
    @Test func nativeReceiverRetainsChromaAndRejectsNonuniformPixels() throws {
      let clock = MediaObservationClock()
      let calibration = VideoCalibration(observationClock: clock)
      let receiver = SyntheticVideoReceiver(calibration: calibration)
      var ledger = VideoSourceLedger(
        clockID: clock.id, fixture: UUID(), direction: .uplink, epoch: 1)
      let anchor = try ledger.anchor(atUs: calibration.nowUs)
      try ledger.stop(atUs: calibration.nowUs)
      var pixelBuffer: CVPixelBuffer?
      #expect(
        CVPixelBufferCreate(
          nil, 8, 8, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pixelBuffer)
          == kCVReturnSuccess)
      let pixels = try #require(pixelBuffer)
      CVPixelBufferLockBaseAddress(pixels, [])
      let y = try #require(CVPixelBufferGetBaseAddressOfPlane(pixels, 0))
      let uv = try #require(CVPixelBufferGetBaseAddressOfPlane(pixels, 1))
      y.initializeMemory(
        as: UInt8.self, repeating: 16,
        count: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) * 8)
      uv.initializeMemory(
        as: UInt8.self, repeating: 128,
        count: CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) * 4)
      CVPixelBufferUnlockBaseAddress(pixels, [])
      let frame = VideoFrame(
        dimensions: Dimensions(width: 8, height: 8), rotation: ._0,
        timeStampNs: 42, rtpTimestamp: 43,
        buffer: CVPixelVideoBuffer(pixelBuffer: pixels))
      receiver.render(frame: frame)
      CVPixelBufferLockBaseAddress(pixels, [])
      uv.assumingMemoryBound(to: UInt8.self)[0] = 200
      CVPixelBufferUnlockBaseAddress(pixels, [])
      receiver.render(frame: frame)
      let report = try calibration.receipt(source: ledger, anchor: anchor)
      #expect(report.contentFreeFrames == 1)
      #expect(report.ambiguousBoundaryFrames == 1)
      #expect(report.preBoundaryDrainUs == nil)
      #expect(report.arrivals.first?.provenance.bufferType == .pixelBuffer)
      #expect(report.arrivals.first?.provenance.mediaTimestampNs == 42)
      #expect(report.arrivals.first?.provenance.rtpTimestamp == 43)
      #expect(report.arrivals.first?.provenance.u?.minimum == 128)
      #expect(report.arrivals.last?.provenance.u?.maximum == 200)
    }
    @Test func seedsWithoutCameraAndStopsAtTheFinalProducerCounter() async throws {
      let source = try await SyntheticVideoCapture.make(
        fixture: UUID(), direction: .uplink,
        epoch: 1, observationClock: MediaObservationClock())
      let track = await source.track
      #expect(track.capturer is BufferCapturer)
      #expect(await source.snapshot().generated.count == 1)
      try await source.captureFrame()
      let stopped = try await source.stop()
      #expect(stopped.finalCounter == 1)
      #expect(stopped.finalEpoch == 1)
      #expect(stopped.pacingTaskJoined)
      #expect(stopped.stoppedAtUs != nil)
      await #expect(throws: VideoMarker.Failure.stopped) { try await source.captureFrame() }
      #expect(await source.snapshot().postStopCaptureRejects == 1)
      #expect(await source.snapshot().generated == stopped.generated)
      _ = try await source.track.stop()
    }

    @Test func stopBeforePacingStartsNeverResumesGeneration() async throws {
      let source = try await SyntheticVideoCapture.make(
        fixture: UUID(), direction: .uplink, epoch: 5, observationClock: MediaObservationClock())
      let final = try await source.stop()
      try await source.run(clock: ContinuousClock(), duration: .seconds(1))
      let after = await source.snapshot()
      #expect(after.generated == final.generated)
      #expect(after.finalCounter == final.finalCounter)
      #expect(after.pacingTaskJoined)
      #expect(after.postStopCaptureRejects == 0)
      _ = try await source.track.stop()
    }

    @Test func stopJoinsActivePacingBeforeReturningTheFinalReceipt() async throws {
      let source = try await SyntheticVideoCapture.make(
        fixture: UUID(), direction: .uplink, epoch: 3, observationClock: MediaObservationClock())
      let pacingClock = TestClock()
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await source.run(clock: pacingClock, duration: .seconds(5)) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while pacingClock.pendingSleepCount == 0, ContinuousClock.now < deadline {
          await Task.yield()
        }
        #expect(await source.snapshot().pacingTaskJoined == false)
        #expect(pacingClock.pendingSleepCount == 1)
        let stopped = try await source.stop()
        #expect(stopped.pacingTaskJoined)
        #expect(pacingClock.pendingSleepCount == 0)
        #expect(stopped.finalEpoch == 3)
        await #expect(throws: VideoMarker.Failure.stopped) { try await source.captureFrame() }
        let after = await source.snapshot()
        #expect(after.generated == stopped.generated)
        #expect(after.finalCounter == stopped.finalCounter)
        #expect(after.postStopCaptureRejects == 1)
        try await group.waitForAll()
      }
      _ = try await source.track.stop()
    }

    private struct Fixture: Decodable {
      let url: String
      let publisherToken: String
      let subscriberToken: String
      let width: Int
      let height: Int
    }
    /// Opt-in calibration uses two native rooms on one clock and the existing external fixture server.
    /// Credentials live in a private simulator file, never in output or process arguments.
    @Test(
      .enabled(if: ProcessInfo.processInfo.environment["VIDEO_CALIBRATION_FIXTURE"] != nil),
      .timeLimit(.minutes(1)))
    func roomCodecCalibration() async throws {
      let path = try #require(ProcessInfo.processInfo.environment["VIDEO_CALIBRATION_FIXTURE"])
      let fixture = try JSONDecoder().decode(
        Fixture.self, from: Data(contentsOf: URL(filePath: path)))
      let publisher = Room()
      let subscriber = Room()
      var source: SyntheticVideoCapture?
      do {
        let clock = MediaObservationClock()
        let calibration = VideoCalibration(observationClock: clock)
        let receiver = SyntheticVideoReceiver(calibration: calibration)
        try await subscriber.connect(url: fixture.url, token: fixture.subscriberToken)
        try await publisher.connect(url: fixture.url, token: fixture.publisherToken)
        let camera = try await SyntheticVideoCapture.make(
          fixture: UUID(), direction: .uplink,
          epoch: 1, observationClock: clock, width: fixture.width, height: fixture.height)
        source = camera
        let anchor = try await camera.anchor()
        let publication = try await publisher.localParticipant.publish(
          videoTrack: camera.track,
          options: VideoPublishOptions(
            simulcast: false, preferredCodec: .vp8,
            preferredBackupCodec: .none, degradationPreference: .maintainResolution))
        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask { try await camera.run(clock: ContinuousClock(), duration: .seconds(5)) }
          let timeout = ContinuousClock.now.advanced(by: .seconds(4))
          var remote: RemoteVideoTrack?
          while ContinuousClock.now < timeout, remote == nil {
            remote =
              subscriber.remoteParticipants.values.compactMap {
                $0.videoTracks.first?.track as? RemoteVideoTrack
              }.first
            if remote == nil { try await Task.sleep(for: .milliseconds(50)) }
          }
          let track = try #require(remote)
          track.add(videoRenderer: receiver)
          calibration.record(.receiverAttached)
          defer { track.remove(videoRenderer: receiver) }
          try await group.waitForAll()
          _ = try await camera.stop()
          try await publisher.localParticipant.unpublish(publication: publication)
          calibration.record(.publicationUnpublished)
          for _ in 0..<20 {
            calibration.record(.receiverHeartbeat)
            try await Task.sleep(for: .milliseconds(100))
          }
          let report = try calibration.receipt(source: await camera.snapshot(), anchor: anchor)
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.sortedKeys]
          print("VIDEO_CALIBRATION " + String(decoding: try encoder.encode(report), as: UTF8.self))
          #expect(report.firstFrameLatencyUs != nil)
          #expect(!report.overflow)
          #expect(report.postBoundaryFrames == 0)
          // Corrupt/ambiguous callbacks stay unqualified; this smoke only checks measurement plumbing.
          #expect(report.unmatchedFrames == 0)
          calibration.record(.receiverDetached)
        }
      } catch {
        if let source {
          _ = try? await source.stop()
          _ = try? await source.track.stop()
        }
        await publisher.disconnect()
        await subscriber.disconnect()
        // Do not include third-party errors that could contain fixture credentials.
        Issue.record("Video calibration setup or execution failed")
        return
      }
      if let source { _ = try? await source.track.stop() }
      await publisher.disconnect()
      await subscriber.disconnect()
    }
  }
#endif
