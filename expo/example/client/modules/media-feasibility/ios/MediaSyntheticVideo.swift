#if DEBUG && targetEnvironment(simulator)
  import Foundation
  import LiveKitClient
  import VoIPConversations

  /// Opt-in media owner on the existing audio Room and observation clock.
  @MainActor final class MediaSyntheticVideo: MediaVideoTransport {
    struct Epoch: Encodable {
      let epoch: UInt32
      let anchor: VideoSourceLedger.Anchor
      let publicationSID: String?
      let source: VideoSourceLedger
    }
    struct Action: Encodable {
      enum Kind: String, Encodable {
        case published, heldSourceStarted, muted, stopped, receiverAttached, receiverDetached,
          roomDisconnected, roomReconnecting, farEndDisconnected,
          remotePublished, remoteUnpublished, remoteUnsubscribed, receiverReplaced, lateSubscription
      }
      let kind: Kind
      let atMs: Double
      let publicationSID: String?
    }
    struct Remote: Encodable {
      let publicationSID: String
      let observation: VideoCalibration.Observation
    }
    private struct Receiver {
      let sid: String
      let track: RemoteVideoTrack
      let renderer: SyntheticVideoReceiver
      let recorder: VideoCalibration
    }
    struct Snapshot: Encodable {
      let clockID: UUID
      let observedAtMs: Double
      let receivers: [Remote]
      let publicationSID: String?
      let publicationMuted: Bool?
      let publicationStopping: Bool
      let roomConnected: Bool
      let remotePublications: [String]
      let epochs: [Epoch]
      let actions: [Action]
      let overflow: Bool
      let failure: MediaJourneyFailure?
    }
    private let room: Room
    private let clock: MediaObservationClock
    private let fixture: UUID
    private var source: SyntheticVideoCapture?
    private var publication: LocalTrackPublication?
    private var anchor: VideoSourceLedger.Anchor?
    private var epoch: UInt32 = 0
    private var pacing: Task<Void, Never>?
    private var receivers: [Receiver] = []
    private var receiversClosed = false
    private var completed: [Epoch] = []
    private var actions: [Action] = []
    private var overflow = false
    private var failure: MediaJourneyFailure?
    init(room: Room, clock: MediaObservationClock, fixture: UUID) {
      self.room = room
      self.clock = clock
      self.fixture = fixture
    }
    func start(epoch: UInt32, muted: Bool) async throws {
      guard source == nil, completed.count < 64 else { throw MediaVideoPolicy.Failure.exhausted }
      let camera = try await SyntheticVideoCapture.make(
        fixture: fixture, direction: .uplink, epoch: epoch, observationClock: clock,
        width: 160, height: 120)
      // Retain ownership before any throwing operation so terminal cleanup can always stop it.
      source = camera
      self.epoch = epoch
      anchor = try await camera.anchor()
      let track = await camera.track
      if !muted {
        publication = try await room.localParticipant.publish(
          videoTrack: track,
          options: VideoPublishOptions(
            simulcast: false, preferredCodec: .vp8, preferredBackupCodec: .none,
            degradationPreference: .maintainResolution))
        record(.published, sid: publication?.sid.stringValue)
      } else {
        record(.heldSourceStarted)
      }
      pacing = Task { [weak self] in
        do {
          try await camera.run(clock: ContinuousClock(), duration: .seconds(180))
          if await camera.snapshot().stoppedAtUs == nil { throw MediaVideoPolicy.Failure.expired }
        } catch {
          self?.failure = MediaJourneyFailure(error, operation: .video)
        }
      }
    }
    func mute() async throws {
      guard let publication else { throw MediaVideoPolicy.Failure.ended }
      try await publication.mute()
      record(.muted, sid: publication.sid.stringValue)
    }
    func stop() async throws {
      guard let camera = source else { return }
      _ = try await camera.stop()
      await pacing?.value
      pacing = nil
      // Prove that a subsequent push is rejected by the actual stopped source.
      do { try await camera.captureFrame() } catch VideoMarker.Failure.stopped {}
      let ledger = await camera.snapshot()
      // Clear only after joining capture; retrying cleanup after an unpublish failure is safe.
      if let publication {
        try await room.localParticipant.unpublish(publication: publication)
        record(.stopped, sid: publication.sid.stringValue)
      } else {
        _ = try await camera.track.stop()
        record(.stopped)
      }
      if let anchor {
        completed.append(
          Epoch(
            epoch: epoch, anchor: anchor, publicationSID: publication?.sid.stringValue,
            source: ledger))
      }
      source = nil
      publication = nil
      anchor = nil
    }
    func attach(_ track: RemoteVideoTrack, sid: String) {
      guard !receiversClosed else {
        overflow = true
        record(.lateSubscription, sid: sid)
        return
      }
      if let prior = receivers.first(where: { $0.sid == sid }) {
        if prior.track !== track {
          overflow = true
          record(.receiverReplaced, sid: sid)
        }
        return
      }
      guard receivers.count < 64 else {
        overflow = true
        return
      }
      let recorder = VideoCalibration(observationClock: clock)
      let renderer = SyntheticVideoReceiver(calibration: recorder)
      track.add(videoRenderer: renderer)
      recorder.record(.receiverAttached)
      receivers.append(Receiver(sid: sid, track: track, renderer: renderer, recorder: recorder))
      record(.receiverAttached, sid: sid)
    }
    func heartbeat() {
      for receiver in receivers { receiver.recorder.record(.receiverHeartbeat) }
    }
    func closeReceivers() {
      guard !receiversClosed else { return }
      receiversClosed = true
      for receiver in receivers {
        receiver.track.remove(videoRenderer: receiver.renderer)
        receiver.recorder.record(.receiverDetached)
        record(.receiverDetached, sid: receiver.sid)
      }
    }
    func snapshot() async -> Snapshot {
      var epochs = completed
      if let source, let anchor {
        let ledger = await source.snapshot()
        epochs = completed
        if self.source === source {
          epochs.append(
            Epoch(
              epoch: epoch, anchor: anchor, publicationSID: publication?.sid.stringValue,
              source: ledger))
        }
      }
      let decoded = receivers.map {
        Remote(publicationSID: $0.sid, observation: $0.recorder.observation())
      }
      return Snapshot(
        clockID: clock.id, observedAtMs: clock.milliseconds,
        receivers: decoded,
        publicationSID: publication?.sid.stringValue, publicationMuted: publication?.isMuted,
        publicationStopping: publication != nil && epochs.last?.source.stoppedAtUs != nil,
        roomConnected: room.connectionState == .connected,
        remotePublications: room.remoteParticipants.values.filter {
          $0.identity?.stringValue == "far-end"
        }
        .flatMap { $0.videoTracks.map { $0.sid.stringValue } }.sorted(), epochs: epochs,
        actions: actions, overflow: overflow, failure: failure)
    }
    func record(_ kind: Action.Kind, sid: String? = nil) {
      guard actions.count < 4096 else {
        overflow = true
        return
      }
      actions.append(Action(kind: kind, atMs: clock.milliseconds, publicationSID: sid))
    }
  }
#endif
