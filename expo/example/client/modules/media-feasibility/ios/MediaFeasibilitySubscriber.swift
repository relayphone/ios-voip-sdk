import ExpoModulesCore
import UIKit

public final class MediaFeasibilitySubscriber: ExpoAppDelegateSubscriber {
  public func application(
    _ application: UIApplication,
    willFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    #if DEBUG && targetEnvironment(simulator)
      if let fixture = try? JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Fixture.path))
      {
        let bridge = NativeRoom(fixture)
        NativeCallMedia.register(RoomMedia(bridge), observers: [bridge])
      }
    #endif
    return true
  }
}

#if DEBUG && targetEnvironment(simulator)
  import AVFAudio
  import LiveKitClient
  @_spi(MediaTransport) import VoIPConversations
  import Synchronization

  private final class PacketEvents: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<MediaTransportEvent>.Continuation]>([:])
    func stream() -> AsyncStream<MediaTransportEvent> {
      let id = UUID()
      let pair = AsyncStream<MediaTransportEvent>.makeStream()
      continuations.withLock { $0[id] = pair.continuation }
      pair.continuation.onTermination = { [weak self] _ in
        self?.continuations.withLock { _ = $0.removeValue(forKey: id) }
      }
      return pair.stream
    }
    func emit(_ event: MediaTransportEvent) {
      let sinks = continuations.withLock { Array($0.values) }
      for sink in sinks { sink.yield(event) }
    }
    deinit { for sink in continuations.withLock({ Array($0.values) }) { sink.finish() } }
  }

  private enum MarkerProfile: String, Decodable, Sendable { case tonesV2 = "tones-v2" }
  private struct Fixture: Decodable, Sendable {
    let profile: MarkerProfile
    let url: String
    let token: String
    let control: String
    let uplinkFrequencies: [Double]
    let journey: MediaJourneyFixture?
    static var path: URL { URL.documentsDirectory.appending(path: "media-fixture.json") }
  }

  private enum AudioCommand: Sendable { case activate, deactivate, release }

  @VoIPActor
  private final class RoomMedia: CallMedia {
    let bridge: NativeRoom
    nonisolated let commands: AsyncStream<AudioCommand>.Continuation
    nonisolated init(_ bridge: NativeRoom) {
      self.bridge = bridge
      commands = bridge.commands
    }
    func transportEvents() -> AsyncStream<MediaTransportEvent> { bridge.packetEvents.stream() }
    func prepare(_ call: Call) async throws {
      bridge.startup.record(.prepareEntered)
      do { try await bridge.prepare(call.id) } catch {
        await bridge.recordJourneyFailure(error, operation: .prepare)
        throw error
      }
      bridge.startup.record(.prepareCompleted)
    }
    func activate() {
      bridge.startup.record(.activationEntered)
      switch commands.yield(.activate) {
      case .enqueued: bridge.startup.record(.activationEnqueued(.enqueued))
      case .dropped: bridge.startup.record(.activationEnqueued(.dropped))
      case .terminated: bridge.startup.record(.activationEnqueued(.terminated))
      @unknown default: break
      }
    }
    func deactivate() { commands.yield(.deactivate) }
    func release(_ call: Call) { commands.yield(.release) }
  }

  @MainActor
  private final class NativeRoom: NSObject, CallObserver, RoomDelegate {
    enum Phase: String, Encodable {
      case setup, duplex, codec, captureProcessing, outputGate, publicationGate, missingTap,
        teardown
    }
    struct Result: Encodable {
      let profile = "tones-v2"
      let generatedSamples: Int64
      let passed: Bool
      let decoded: MediaAudioProbe.Observation
      let output: MediaAudioProbe.Observation
      let mutedOutput: MediaAudioProbe.Observation
      let missingTapCaught: Bool
      let inactiveEngineStayedStopped: Bool
      let processing: [String: Bool]
      let processingEvidence: MediaProcessingEvidence?
      let processingTimeline: [MediaProcessingTimeline.Entry]
      let processingTimelineDropped: Int
      let codecs: [String: String]
      let silenceWindows: [PCMSilenceWindows.Window]
      let teardown: MediaTeardownEvidence.Receipt
      let startup: MediaStartupEvidence.Receipt
    }
    nonisolated let commands: AsyncStream<AudioCommand>.Continuation
    nonisolated let startup: MediaStartupEvidence
    let observationClock: MediaObservationClock
    let probe: MediaAudioProbe
    let teardown: MediaTeardownEvidence
    let fixture: Fixture
    let room = Room()
    nonisolated let packetEvents = PacketEvents()
    var packets: Task<Void, Never>?
    let decoder: DecodedAudioProbe
    let hooks: MarkerAudioEngine
    var events: Task<Void, Never>?
    var audio: Task<Void, Never>?
    var observer: Task<Void, Never>?
    weak var client: VoIPClient?
    var journeySession: MediaJourneySession?
    var journeyPhaseAtMs: Double?
    var journeyTicks: [Double] = []
    var journeyTicksDropped = 0
    var journeyEnded: JourneyEnd?
    var sdkCallHistory = MediaSDKAudioState.CallHistory()
    var syntheticVideo: MediaSyntheticVideo?
    var videoPolicy: MediaVideoPolicy?
    var syntheticVideoEvidence: MediaSyntheticVideo.Snapshot?
    var videoTerminating = false
    var videoHistory = MediaSDKVideoEvidence.History()
    var journeyFailure: MediaJourneyFailure?
    var publicationHeld = false
    var publicationMuted = false
    var audioEngineStoppedAtMs: Double?
    var heldOutputStartAtMs: Double?
    var inactiveEngineStayedStopped = false
    var active = false
    var released = false
    var phase = Phase.setup
    var failed = false
    struct TransportSnapshot: Encodable {
      let sample: Int
      let packetsLost: Int64
      let concealedSamples: UInt64
      let insertedSamples: UInt64
      let removedSamples: UInt64
      let timestamp: Double
      let streamID: String
    }
    struct CapturedPCM: Encodable {
      let sampleRate: Double
      let channels: [[Float]]
      let formatChanged: Bool
      let transport: [TransportSnapshot]
    }
    var transport: [MediaAudioProbe.Stage: [TransportSnapshot]] = [:]
    var lastStatisticsTimestamp: Double?
    var savedDuplex = false
    var processing: [String: Bool] = [:]
    var appliedProcessing: MediaProcessingEvidence.Configuration?
    var processingEvidence: MediaProcessingEvidence?
    var codecs: [String: String] = [:]
    var silenceWindows: [PCMSilenceWindows.Window] = []
    var localTrack: LocalAudioTrack?
    var remoteTrack: RemoteAudioTrack?
    init(_ fixture: Fixture) {
      self.fixture = fixture
      let observationClock = MediaObservationClock()
      self.observationClock = observationClock
      probe = MediaAudioProbe(
        observationClock: observationClock,
        captureDuration: fixture.journey?.syntheticVideo == nil ? .seconds(10) : .seconds(4))
      startup = probe.startup
      teardown = MediaTeardownEvidence(observationClock: observationClock)
      decoder = DecodedAudioProbe(probe: probe)
      hooks = MarkerAudioEngine(probe: probe, frequencies: fixture.uplinkFrequencies)
      let stream = AsyncStream<AudioCommand>.makeStream()
      commands = stream.continuation
      super.init()
      if let token = fixture.journey?.syntheticVideo {
        let video = MediaSyntheticVideo(room: room, clock: observationClock, fixture: token)
        syntheticVideo = video
        videoPolicy = MediaVideoPolicy(transport: video)
      }
      audio = Task { [weak self] in
        for await command in stream.stream {
          guard let self else { return }
          do {
            switch command {
            case .activate:
              audioEngineStoppedAtMs = nil
              probe.startup.record(.activationHandlerEntered)
              probe.beginWindow()
              hooks.processingTimeline.record(.engineAvailabilityApplying)
              defer {
                probe.startup.record(
                  .engineAvailabilityObserved(
                    AudioManager.shared.isEngineRunning ? .running : .unavailable))
              }
              try AudioManager.shared.setEngineAvailability(.default)
              hooks.processingTimeline.record(
                .engineAvailabilityApplied, engineRunning: AudioManager.shared.isEngineRunning)
              active = true
            case .deactivate:
              try AudioManager.shared.setEngineAvailability(.none)
              active = false
              if !AudioManager.shared.isEngineRunning {
                audioEngineStoppedAtMs = observationClock.milliseconds
                teardown.record(.engineStopped)
              }
            case .release:
              // The SDK queues release before delivering its ended event to the app.
              if syntheticVideo != nil, teardown.receipt() != nil {
                try await until { self.journeyEnded != nil }
              }
              videoTerminating = true
              do { try await applyVideo(hasVideo: false, held: false, ended: true) } catch {
                recordJourneyFailure(error, operation: .video)
                fail()
              }
              packets?.cancel()
              packets = nil
              await room.disconnect()
              syntheticVideo?.record(.roomDisconnected)
              if room.connectionState == .disconnected { teardown.record(.roomDisconnected) }
              decoder.detach()
              hooks.uninstallOutputTap()
              if !probe.observation(.output).installed && !probe.observation(.decoded).installed {
                teardown.record(.tapUninstalled)
              }
              released = true
            }
            if released && !active { commands.finish() }
          } catch { fail() }
        }
        await self?.room.disconnect()
      }
    }
    func prepare(_ callID: CallID) async throws {
      let manager = AudioManager.shared
      manager.audioSession.isAutomaticConfigurationEnabled = false
      manager.set(engineObservers: [manager.audioSession, manager.mixer, hooks])
      try manager.setEngineAvailability(.none)
      // The marker joins downstream of the hardware input, so mute the mixed capture.
      try manager.set(microphoneMuteMode: .inputMixer)
      room.add(delegate: self)
      probe.startup.record(.roomConnectRequested)
      do {
        try await room.connect(url: fixture.url, token: fixture.token)
        probe.startup.record(.roomConnectCompleted)
      } catch {
        probe.startup.record(.roomConnectFailed(errorType: String(reflecting: type(of: error))))
        throw error
      }
      let captureOptions = MarkerAudioEngine.syntheticCaptureOptions
      hooks.processingTimeline.record(.captureOptionsApplying)
      appliedProcessing = .init(
        aec: captureOptions.echoCancellation, ns: captureOptions.noiseSuppression,
        agc: captureOptions.autoGainControl)
      let publication = try await room.localParticipant.setMicrophone(
        enabled: true,
        captureOptions: captureOptions)
      hooks.processingTimeline.record(.captureOptionsApplied)
      probe.startup.record(.captureOptionsApplied)
      localTrack = publication?.track as? LocalAudioTrack
      await localTrack?.set(reportStatistics: true)
      inactiveEngineStayedStopped =
        !manager.isEngineRunning && probe.observation(.output).samples == 0
      guard inactiveEngineStayedStopped else { throw MediaAudioProbe.Failure.audioLeaked(.output) }
      try Task.checkCancellation()
      packets?.cancel()
      packets = Task { [weak self] in
        await MediaPacketSampler.observe(
          callID: callID, clock: ContinuousClock(),
          ready: { [weak self] in self?.active == true },
          sample: { [weak self] received, sent in
            guard let self else { return (false, false) }
            return (
              received
                && (remoteTrack?.statistics?.inboundRtpStream.contains {
                  ($0.packetsReceived ?? 0) > 0
                } ?? false),
              sent
                && (localTrack?.statistics?.outboundRtpStream.contains {
                  ($0.packetsSent ?? 0) > 0
                } ?? false)
            )
          }, emit: { [weak self] in self?.packetEvents.emit($0) })
      }
    }

    deinit { packets?.cancel() }
    nonisolated func room(
      _ room: Room, participant: RemoteParticipant,
      didSubscribeTrack publication: RemoteTrackPublication
    ) {
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let track = publication.track as? RemoteVideoTrack,
          participant.identity?.stringValue == "far-end"
        {
          if released {
            syntheticVideo?.record(.lateSubscription, sid: publication.sid.stringValue)
          } else {
            syntheticVideo?.attach(track, sid: publication.sid.stringValue)
          }
          return
        }
        guard !released, let track = publication.track as? RemoteAudioTrack else { return }
        decoder.attach(to: track)
        remoteTrack = track
        await track.set(reportStatistics: true)
      }
    }
    nonisolated func room(
      _ room: Room, participant: RemoteParticipant,
      didPublishTrack publication: RemoteTrackPublication
    ) {
      recordRemoteVideo(participant, publication, .remotePublished)
    }
    nonisolated func room(
      _ room: Room, participant: RemoteParticipant,
      didUnpublishTrack publication: RemoteTrackPublication
    ) {
      recordRemoteVideo(participant, publication, .remoteUnpublished)
    }
    nonisolated func room(
      _ room: Room, participant: RemoteParticipant,
      didUnsubscribeTrack publication: RemoteTrackPublication
    ) {
      recordRemoteVideo(participant, publication, .remoteUnsubscribed)
    }
    private nonisolated func recordRemoteVideo(
      _ participant: RemoteParticipant, _ publication: RemoteTrackPublication,
      _ kind: MediaSyntheticVideo.Action.Kind
    ) {
      guard participant.identity?.stringValue == "far-end", publication.kind == .video else {
        return
      }
      Task { @MainActor [weak self] in
        self?.syntheticVideo?.record(kind, sid: publication.sid.stringValue)
      }
    }
    nonisolated func room(_ room: Room, didStartReconnectWithMode _: ReconnectMode) {
      Task { @MainActor [weak self] in self?.syntheticVideo?.record(.roomReconnecting) }
    }
    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
      // LiveKit resets the participant state after its delegate returns.
      guard let identity = participant.identity, identity.stringValue == "far-end",
        room.connectionState == .connected, room.remoteParticipants[identity] == nil
      else { return }
      Task { @MainActor [weak self] in
        guard let self, fixture.journey != nil else { return }
        syntheticVideo?.record(.farEndDisconnected)
        guard let receipt = teardown.receipt(), !receipt.complete, journeyEnded == nil,
          let client,
          let call = client.calls.first(where: { $0.id.rawValue == fixture.journey?.conversationId }
          )
        else { return }
        await client.receive(
          .endedRemotely, for: call.id, eventID: EventID(rawValue: UUID().uuidString))
      }
    }
    func attach(to client: VoIPClient) {
      self.client = client
      let stream = client.events()
      observer = Task { [weak self] in
        for await event in stream {
          guard let self else { return }
          if case .audioActivated = event { startup.recordAudioEvent(.activated) }
          if case .audioDeactivated = event {
            startup.recordAudioEvent(.deactivated)
            teardown.record(.audioSessionReleased)
          }
          if case .ended(let call) = event,
            call.id.rawValue == (fixture.journey?.conversationId ?? "media-example")
          {
            sdkCallHistory.recordEnded(
              failure: sdkCallStatus(call).failure, atMs: observationClock.milliseconds)
          }
          if case .ended(let call) = event, call.id.rawValue == fixture.journey?.conversationId {
            let endedAtMs = observationClock.milliseconds
            videoHistory.record(
              .ended, hasVideo: call.hasVideo, connected: false, atMs: endedAtMs
            )
            let reason: JourneyEnd.Reason
            switch call.status {
            case .ended(.localDeclined), .ended(.localEnded): reason = .local
            case .ended(.endedRemotely): reason = .remoteEnded
            default: reason = .unexpected
            }
            journeyEnded = JourneyEnd(reason: reason, atMs: endedAtMs)
            videoTerminating = true
            do { try await applyVideo(hasVideo: false, held: false, ended: true) } catch {
              recordJourneyFailure(error, operation: .video)
              fail()
            }
          }
          if case .videoChanged(let call, let source) = event,
            call.id.rawValue == fixture.journey?.conversationId
          {
            videoHistory.record(
              .changed, hasVideo: call.hasVideo, connected: call.status == .connected,
              source: source == .app ? .app : .server, atMs: observationClock.milliseconds)
            if !videoTerminating,
              !call.hasVideo
                || (call.status == .connected && active && client.isAudioActive
                  && room.connectionState == .connected)
            {
              do {
                try await applyVideo(hasVideo: call.hasVideo, held: call.isOnHold)
              } catch {
                recordJourneyFailure(error, operation: .video)
                fail()
              }
            }
          }
          if case .performed(.hold(_, let held), let call) = event,
            call.id.rawValue == fixture.journey?.conversationId
          {
            videoHistory.record(
              held ? .held : .resumed, hasVideo: call.hasVideo,
              connected: call.status == .connected, atMs: observationClock.milliseconds)
            do {
              AudioManager.shared.mixer.outputVolume = held ? 0 : 1
              if !videoTerminating {
                try await applyVideo(hasVideo: call.hasVideo, held: held)
              }
              try await room.localParticipant.setMicrophone(enabled: !held && !call.isMuted)
              publicationHeld = held
            } catch { fail() }
          }
          if case .performed(.mute(_, let muted), let call) = event,
            fixture.journey == nil || call.id.rawValue == fixture.journey?.conversationId
          {
            do {
              try await room.localParticipant.setMicrophone(
                enabled: !muted && !call.isOnHold)
              publicationMuted = muted
            } catch { fail() }
          }
        }
      }
      events = Task { [weak self, weak client] in
        guard let self, let client else { return }
        do {
          if fixture.journey != nil {
            try await runJourney(client)
            return
          }
          let clock = ContinuousClock()
          let resultDeadline = try await phaseDeadline(clock: clock)
          let party = Party(handle: try Handle(kind: .generic, value: "media-peer"))
          let incoming = IncomingCall(id: CallID(rawValue: "media-example"), parties: [party])
          _ = await client.report(incoming)
          try await client.request(.answer(incoming.id))
          phase = .duplex
          // Keep the existing ten-second acquisition deadline; retain later repeated cycles.
          let acquisitionDeadline = clock.now + .seconds(10)
          while clock.now < acquisitionDeadline {
            hooks.processingTimeline.record(
              .acquisition, engineRunning: AudioManager.shared.isEngineRunning)
            recordTransport()
            try await clock.sleep(until: min(acquisitionDeadline, clock.now + .milliseconds(100)))
          }
          recordTransport()
          guard probe.observation(.output).frameSeconds >= 3,
            probe.observation(.decoded).frameSeconds >= 3
          else { throw MediaAudioProbe.Failure.incompleteWindow(.decoded) }
          saveDuplex()
          phase = .codec
          codecs = [
            "fromDevice": codec(localTrack, outbound: true),
            "toDevice": codec(remoteTrack, outbound: false),
          ]
          guard codecs.values.allSatisfy({ $0 == "audio/opus" || $0 == "audio/red(opus)" }) else {
            throw MediaAudioProbe.Failure.signalMissing(.decoded)
          }
          phase = .captureProcessing
          let state = hooks.processingTimeline.record(
            .checkRead, engineRunning: AudioManager.shared.isEngineRunning)
          var requested: [MediaProcessingEvidence.Effect: Bool] = [:]
          for (effect, value) in [
            (MediaProcessingEvidence.Effect.aec, state.aec.requested),
            (.ns, state.ns.requested), (.agc, state.agc.requested),
          ] where value != .unavailable {
            requested[effect] = value == .enabled
          }
          let evidence = MediaProcessingEvidence(
            expected: .init(aec: false, ns: false, agc: true), applied: appliedProcessing,
            active: .init(aec: state.aec.active, ns: state.ns.active, agc: state.agc.active),
            engineRunning: state.engineRunning == true, requested: requested)
          processingEvidence = evidence
          processing = [
            "aecActive": state.aec.active, "nsActive": state.ns.active,
            "agcActive": state.agc.active,
          ]
          for (effect, value) in requested { processing[effect.rawValue + "Requested"] = value }
          guard evidence.passed else { throw MediaAudioProbe.Failure.signalMissing(.decoded) }
          phase = .duplex
          try probe.expectAudio(.decoded)
          try probe.expectAudio(.output)
          let decoded = probe.observation(.decoded)
          let output = probe.observation(.output)
          // The source remains unchanged; these are LiveKit's real output/publication gates.
          phase = .outputGate
          AudioManager.shared.mixer.outputVolume = 0
          try await Task.sleep(for: .milliseconds(300))
          probe.beginWindow()
          probe.beginSilence(
            .output, for: .seconds(1), remaining: clock.now.duration(to: resultDeadline))
          while let attempt = probe.silence(.output) {
            let checkpoint = URL.documentsDirectory.appending(path: "media-silence-windows.json")
            if attempt.windows.count != silenceWindows.count
              || !FileManager.default.fileExists(atPath: checkpoint.path)
            {
              silenceWindows = attempt.windows
              try JSONEncoder().encode(attempt.snapshot).write(to: checkpoint, options: .atomic)
            }
            if let verdict = attempt.verdict {
              guard verdict == .silent else {
                throw MediaAudioProbe.Failure.incompleteWindow(.output)
              }
              break
            }
            try await clock.sleep(until: min(resultDeadline, clock.now + .milliseconds(20)))
          }
          try probe.expectAudio(.decoded)
          let mutedOutput = probe.observation(.output)
          AudioManager.shared.mixer.outputVolume = 1
          phase = .publicationGate
          try await control("leak-control")  // Unmuted audio must fail the peer's silence check.
          try await client.request(.mute(incoming.id, muted: true))
          try await until { self.publicationMuted }
          try await control("muted")
          phase = .missingTap
          var caught = false
          do { try MediaAudioProbe().expectSilence(.output) } catch MediaAudioProbe.Failure
            .missingTap(.output)
          { caught = true }
          guard caught else {
            fail()
            return
          }
          teardown.begin()
          try await client.request(.end(incoming.id))
          phase = .teardown
          try await until {
            self.released && !self.active && self.teardown.receipt()?.complete == true
          }
          guard let teardownReceipt = teardown.receipt(), teardownReceipt.complete else {
            throw MediaAudioProbe.Failure.missingTap(.output)
          }
          guard !failed else { return }
          let result = Result(
            generatedSamples: hooks.generatedSamples, passed: true, decoded: decoded,
            output: output,
            mutedOutput: mutedOutput, missingTapCaught: caught,
            inactiveEngineStayedStopped: inactiveEngineStayedStopped, processing: processing,
            processingEvidence: processingEvidence,
            processingTimeline: hooks.processingTimeline.entries,
            processingTimelineDropped: hooks.processingTimeline.dropped,
            codecs: codecs, silenceWindows: silenceWindows, teardown: teardownReceipt,
            startup: probe.startup.receipt())
          try JSONEncoder().encode(result).write(
            to: URL.documentsDirectory.appending(path: "media-result.json"))

        } catch { fail() }
      }
    }
    struct JourneyEnd: Encodable {
      enum Reason: String, Encodable { case local, remoteEnded, unexpected }
      let reason: Reason
      let atMs: Double
    }
    struct JourneySnapshot: Encodable {
      enum AudioMode: String, Encodable { case voice, video, other }
      struct Stage: Encodable {
        let pcm: CapturedPCM?
        let sampleRate: Double
        let retainedSamples: Int
        let transportCount: Int
        let lastTransportSample: Int
        let observation: MediaAudioProbe.Observation
        let droppedCallbacks: Int
        let lastCallbackAtMs: Double?
      }
      let commandId: UUID?
      let sessionId: UUID
      let fixtureId: String
      let conversationId: String
      let clockId: UUID
      let phaseId: String?
      let phaseAtMs: Double?
      let observedAtMs: Double
      let monitorTicksMs: [Double]
      let droppedMonitorTicks: Int
      let decoded: Stage
      let output: Stage
      let ended: JourneyEnd?
      let teardown: MediaTeardownEvidence.Receipt?
      let released: Bool
      let audioActive: Bool
      let audioEngineRunning: Bool
      let audioOutputAvailable: Bool
      let audioEngineStoppedAtMs: Double?
      let heldOutputStartAtMs: Double?
      let startup: MediaStartupEvidence.Receipt
      let sdkAudioState: MediaSDKAudioState
      let publicationMuted: Bool
      let onHold: Bool
      let audioMode: AudioMode
      let heldOutput: PCMSilenceWindows.Snapshot?
      let outputPorts: [String]
      let video: MediaSDKVideoEvidence
      let syntheticVideo: MediaSyntheticVideo.Snapshot?
      let failure: MediaJourneyFailure?
    }
    private func journeySnapshot(command: UUID?, includePCM: Bool = false) -> JourneySnapshot? {
      guard let session = journeySession else { return nil }
      let video = sdkVideoEvidence()
      let audioSession = AVAudioSession.sharedInstance()
      let mode: JourneySnapshot.AudioMode =
        switch audioSession.mode {
        case .voiceChat: .voice
        case .videoChat: .video
        default: .other
        }
      func stage(_ stage: MediaAudioProbe.Stage) -> JourneySnapshot.Stage {
        let snapshot = probe.snapshot(stage)
        let pcm = snapshot.capture
        let counters = transport[stage] ?? []
        return JourneySnapshot.Stage(
          pcm: includePCM
            ? CapturedPCM(
              sampleRate: pcm.sampleRate, channels: pcm.channels,
              formatChanged: pcm.formatChanged, transport: counters) : nil,
          sampleRate: pcm.sampleRate, retainedSamples: pcm.channels.first?.count ?? 0,
          transportCount: counters.count, lastTransportSample: counters.last?.sample ?? 0,
          observation: snapshot.observation, droppedCallbacks: snapshot.callbacks.droppedFrames,
          lastCallbackAtMs: snapshot.callbacks.frames.lazy.map { $0.atSeconds * 1000 }.max())
      }
      return JourneySnapshot(
        commandId: command, sessionId: session.id, fixtureId: session.fixture.fixtureId,
        conversationId: session.fixture.conversationId, clockId: observationClock.id,
        phaseId: session.phaseId, phaseAtMs: journeyPhaseAtMs,
        observedAtMs: observationClock.milliseconds, monitorTicksMs: journeyTicks,
        droppedMonitorTicks: journeyTicksDropped, decoded: stage(.decoded), output: stage(.output),
        ended: journeyEnded, teardown: teardown.receipt(), released: released,
        audioActive: client?.isAudioActive ?? false,
        audioEngineRunning: AudioManager.shared.isEngineRunning,
        audioOutputAvailable: AudioManager.shared.engineAvailability.isOutputAvailable,
        audioEngineStoppedAtMs: audioEngineStoppedAtMs, heldOutputStartAtMs: heldOutputStartAtMs,
        startup: probe.startup.receipt(),
        sdkAudioState: sdkAudioState(),
        publicationMuted: publicationMuted,
        onHold: client?.calls.first(where: { $0.id.rawValue == session.fixture.conversationId })?
          .isOnHold ?? false, audioMode: mode,
        heldOutput: publicationHeld ? probe.silence(.output)?.snapshot : nil,
        outputPorts: audioSession.currentRoute.outputs.map {
          switch $0.portType {
          case .builtInReceiver: "receiver"
          case .builtInSpeaker: "speaker"
          default: $0.portType.rawValue
          }
        }.sorted(),
        video: video, syntheticVideo: syntheticVideoEvidence,
        failure: journeyFailure)
    }
    private func runJourney(_ client: VoIPClient) async throws {
      guard let fixture = fixture.journey else { return }
      journeySession = try MediaJourneySession(fixture: fixture)
      let callID = CallID(rawValue: fixture.conversationId)
      let party = Party(handle: try Handle(kind: .generic, value: "media-peer"))
      _ = await client.report(
        IncomingCall(id: callID, parties: [party], hasVideo: fixture.initialVideo ?? false))
      do {
        try await client.request(.answer(callID))
        let deadline = ContinuousClock.now + .seconds(10)
        try await until(deadline: deadline) {
          self.active && client.isAudioActive && self.room.connectionState == .connected
            && client.calls.first(where: { $0.id == callID })?.status == .connecting
        }
        // The fixture supplies the server connection event once the actual Room is ready.
        await client.receive(.connected, for: callID, eventID: EventID(rawValue: UUID().uuidString))
        try await until(deadline: deadline) {
          self.active && client.isAudioActive && self.room.connectionState == .connected
            && client.calls.first(where: { $0.id == callID })?.status == .connected
        }
      } catch {
        recordJourneyFailure(error, operation: .connect)
        throw error
      }
      if let call = client.calls.first(where: { $0.id == callID }) {
        videoHistory.record(
          .readySnapshot, hasVideo: call.hasVideo, connected: call.status == .connected,
          atMs: observationClock.milliseconds)
      }
      if let call = client.calls.first(where: { $0.id == callID }), !videoTerminating {
        try await applyVideo(hasVideo: call.hasVideo, held: call.isOnHold)
      }
      syntheticVideoEvidence = await syntheticVideo?.snapshot()
      let directory = URL.documentsDirectory
      try JSONEncoder().encode(journeySnapshot(command: nil)).write(
        to: directory.appending(path: "media-journey-ready.json"), options: .atomic)
      let clock = ContinuousClock()
      let deadline = clock.now + .seconds(180)
      var lastCommand: UUID?
      var lastServerMetadata: String?
      while clock.now < deadline {
        try Task.checkCancellation()
        if publicationHeld, audioEngineStoppedAtMs != nil {
          let manager = AudioManager.shared
          if manager.isEngineRunning || manager.engineAvailability.isOutputAvailable {
            audioEngineStoppedAtMs = nil
          } else if journeyTicks.count < 3001 {
            journeyTicks.append(observationClock.milliseconds)
          } else {
            journeyTicksDropped += 1
          }
        }
        if journeyPhaseAtMs != nil { recordTransport() }
        if publicationHeld { _ = probe.silence(.output) }
        syntheticVideo?.heartbeat()
        // The fixture room carries server updates independently of the local command mailbox.
        if let metadata = room.metadata, metadata != lastServerMetadata {
          lastServerMetadata = metadata
          if !videoTerminating, let update = journeySession?.acceptServerVideo(metadata) {
            do {
              try await client.setVideo(callID, enabled: update.enabled, source: .server)
            } catch {
              recordJourneyFailure(error, operation: .video)
              throw error
            }
          }
        }
        let path = directory.appending(path: "media-journey-command.json")
        if let data = try? Data(contentsOf: path),
          let command = try? JSONDecoder().decode(MediaJourneyCommand.self, from: data),
          command.id != lastCommand
        {
          lastCommand = command.id
          do {
            try journeySession?.accept(command)
            switch command.operation {
            case .beginPhase:
              guard let frequencies = command.frequencies else {
                throw MediaJourneySession.Failure.invalidPhase
              }
              hooks.replaceMarker(frequencies: frequencies)
              journeyPhaseAtMs = observationClock.milliseconds
              resetJourneyCapture()
              journeyTicks = []
              journeyTicksDropped = 0
            case .snapshot, .audioSnapshot: break
            case .mute:
              try await client.request(.mute(callID, muted: command.enabled == true))
              try await until { self.publicationMuted == (command.enabled == true) }
            case .hold:
              let held = command.enabled == true
              try await client.request(.hold(callID, onHold: held))
              try await until { self.publicationHeld == held }
              if held {
                try await clock.sleep(for: .milliseconds(300))
                journeyTicks = []
                heldOutputStartAtMs = observationClock.milliseconds
                probe.beginSilence(
                  .output, for: .seconds(1), remaining: clock.now.duration(to: deadline))
              } else {
                heldOutputStartAtMs = nil
              }
            case .video:
              guard let enabled = command.enabled else {
                throw MediaJourneySession.Failure.invalidArguments
              }
              try await client.setVideo(callID, enabled: enabled)
            case .armTeardown: teardown.begin()
            case .end:
              guard teardown.receipt() != nil else {
                throw MediaJourneySession.Failure.invalidPhase
              }
              try await client.request(.end(callID))
            case .close:
              videoTerminating = true
              try await applyVideo(hasVideo: false, held: false, ended: true)
              syntheticVideo?.closeReceivers()
            }
            recordTransport()
            if command.operation != .audioSnapshot {
              syntheticVideoEvidence = await syntheticVideo?.snapshot()
            }
            try JSONEncoder().encode(
              journeySnapshot(command: command.id, includePCM: command.operation == .audioSnapshot)
            ).write(
              to: directory.appending(path: "media-journey-response.json"), options: .atomic)
            if command.operation == .close { return }
          } catch {
            struct Rejected: Encodable {
              let commandId: UUID
              let rejected = true
              let failure: MediaJourneyFailure
            }
            let failure = MediaJourneyFailure(
              error, operation: command.operation == .video ? .video : .command)
            journeyFailure = journeyFailure ?? failure
            try JSONEncoder().encode(Rejected(commandId: command.id, failure: failure)).write(
              to: directory.appending(path: "media-journey-response.json"), options: .atomic)
          }
        }
        try await clock.sleep(for: .milliseconds(20))
      }
      throw MediaAudioProbe.Failure.incompleteWindow(.output)
    }

    private func until(
      deadline: ContinuousClock.Instant = ContinuousClock.now + .seconds(10),
      _ condition: () -> Bool
    ) async throws {
      let clock = ContinuousClock()
      while clock.now < deadline {
        if condition() { return }
        try await clock.sleep(until: min(deadline, clock.now + .milliseconds(20)))
      }
      throw MediaAudioProbe.Failure.noFrames(.output)
    }
    private func control(_ phase: String) async throws {
      let url = URL(string: fixture.control + "/" + phase)!
      let (_, response) = try await URLSession.shared.data(from: url)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw MediaAudioProbe.Failure.audioLeaked(.output)
      }
    }
    private func phaseDeadline(clock: ContinuousClock) async throws -> ContinuousClock.Instant {
      struct Budget: Decodable { let remainingMs: Double }
      let started = clock.now
      let (data, response) = try await URLSession.shared.data(
        from: URL(string: fixture.control + "/deadline")!)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw MediaAudioProbe.Failure.incompleteWindow(.output)
      }
      let budget = try JSONDecoder().decode(Budget.self, from: data)
      guard budget.remainingMs.isFinite, budget.remainingMs >= 0 else {
        throw MediaAudioProbe.Failure.incompleteWindow(.output)
      }
      // Subtract the entire round trip so the native deadline cannot extend the host budget.
      return started + .milliseconds(budget.remainingMs)
    }
    private func codec(_ track: LiveKitClient.Track?, outbound: Bool) -> String {
      guard let statistics = track?.statistics,
        let id = outbound
          ? statistics.outboundRtpStream.first?.codecId
          : statistics.inboundRtpStream.first?.codecId,
        let codec = statistics.codec.first(where: { $0.id == id }),
        let mime = codec.mimeType?.lowercased()
      else { return "unavailable" }
      if mime == "audio/red", let format = codec.sdpFmtpLine {
        let opusPayloads = statistics.codec.filter { $0.mimeType?.lowercased() == "audio/opus" }
          .compactMap { $0.payloadType.map(String.init) }
        let payloads = format.split(separator: "/")
        if !payloads.isEmpty && payloads.allSatisfy({ opusPayloads.contains(String($0)) }) {
          return "audio/red(opus)"
        }
      }
      return mime
    }
    private func resetJourneyCapture() {
      probe.beginWindow()
      transport = [:]
      lastStatisticsTimestamp = nil
    }
    private func recordTransport() {
      guard let stats = remoteTrack?.statistics?.inboundRtpStream.first,
        stats.timestamp != lastStatisticsTimestamp,
        let lost = stats.packetsLost, let concealed = stats.concealedSamples,
        let inserted = stats.insertedSamplesForDeceleration,
        let removed = stats.removedSamplesForAcceleration
      else { return }
      lastStatisticsTimestamp = stats.timestamp
      for stage in [MediaAudioProbe.Stage.decoded, .output] {
        let capture = probe.capture(stage)
        let channels = max(1, capture.channels.count)
        transport[stage, default: []].append(
          TransportSnapshot(
            sample: probe.observation(stage).samples / channels,
            packetsLost: lost, concealedSamples: concealed,
            insertedSamples: inserted, removedSamples: removed,
            timestamp: stats.timestamp, streamID: stats.id))
      }
    }
    private func saveDuplex() {
      guard !savedDuplex else { return }
      for stage in [MediaAudioProbe.Stage.decoded, .output] {
        let capture = probe.capture(stage)
        let retained = CapturedPCM(
          sampleRate: capture.sampleRate, channels: capture.channels,
          formatChanged: capture.formatChanged, transport: transport[stage] ?? [])
        try? JSONEncoder().encode(retained).write(
          to: URL.documentsDirectory.appending(path: "media-" + stage.rawValue + ".json"))
      }
      savedDuplex = true
    }
    private func sdkCallStatus(_ call: Call) -> (
      status: MediaSDKAudioState.Status, failure: MediaSDKAudioState.Failure?
    ) {
      let status: MediaSDKAudioState.Status
      var failure: MediaSDKAudioState.Failure?
      switch call.status {
      case .ringing: status = .ringing
      case .previewing: status = .previewing
      case .dialing: status = .dialing
      case .connecting: status = .connecting
      case .connected: status = .connected
      case .reconnecting: status = .reconnecting
      case .ended(let reason):
        status = .ended
        if case .failed(let cause) = reason {
          switch cause {
          case .refused: failure = .refused
          case .atCapacity: failure = .atCapacity
          case .notPlaced: failure = .notPlaced
          case .media: failure = .media
          case .audioActivationTimedOut: failure = .audioActivationTimedOut
          case .audioSession: failure = .audioSession
          case .audioRecoveryTimedOut: failure = .audioRecoveryTimedOut
          case .connectTimedOut: failure = .connectTimedOut
          case .reconnectTimedOut: failure = .reconnectTimedOut
          case .actionTimedOut: failure = .actionTimedOut
          case .frameworkReset: failure = .frameworkReset
          case .server: failure = .server
          }
        }
      }
      return (status, failure)
    }
    private func sdkAudioState() -> MediaSDKAudioState {
      let id = fixture.journey?.conversationId ?? "media-example"
      let snapshot = client?.calls.first(where: { $0.id.rawValue == id }).map { call in
        let status = sdkCallStatus(call)
        return MediaSDKAudioState.CallObservation(
          status: status.status, failure: status.failure, source: .snapshot,
          atMs: observationClock.milliseconds)
      }
      let call = sdkCallHistory.observation(snapshot: snapshot)
      return MediaSDKAudioState(
        clockID: observationClock.id, observedAtMs: observationClock.milliseconds,
        isAudioActive: client?.isAudioActive, callStatus: call?.status ?? .unavailable,
        callFailure: call?.failure, callSource: call?.source ?? .unavailable,
        callObservedAtMs: call?.atMs)
    }
    private func sdkVideoEvidence() -> MediaSDKVideoEvidence {
      let call = client?.calls.first(where: { $0.id.rawValue == fixture.journey?.conversationId })
      return MediaSDKVideoEvidence(
        clockID: observationClock.id, observedAtMs: observationClock.milliseconds,
        hasVideo: call?.hasVideo, onHold: call?.isOnHold, connected: call?.status == .connected,
        events: videoHistory.events, overflow: videoHistory.overflow)
    }
    private func applyVideo(hasVideo: Bool, held: Bool, ended: Bool = false) async throws {
      do { try await videoPolicy?.apply(hasVideo: hasVideo, held: held, ended: ended) } catch {
        recordJourneyFailure(error, operation: .video)
        throw error
      }
    }
    func recordJourneyFailure(_ error: any Error, operation: MediaJourneyFailure.Operation) {
      if journeyFailure == nil { journeyFailure = MediaJourneyFailure(error, operation: operation) }
    }
    private func fail() {
      guard !failed else { return }
      if syntheticVideo != nil {
        videoTerminating = true
        Task { [self] in
          do { try await applyVideo(hasVideo: false, held: false, ended: true) } catch {
            recordJourneyFailure(error, operation: .video)
          }
          syntheticVideoEvidence = await syntheticVideo?.snapshot()
          try? JSONEncoder().encode(journeySnapshot(command: nil)).write(
            to: URL.documentsDirectory.appending(path: "media-journey-failure.json"),
            options: .atomic)
        }
      } else if fixture.journey != nil {
        try? JSONEncoder().encode(journeySnapshot(command: nil)).write(
          to: URL.documentsDirectory.appending(path: "media-journey-failure.json"), options: .atomic
        )
      }
      packets?.cancel()
      packets = nil
      failed = true
      saveDuplex()
      struct FailureResult: Encodable {
        let profile = "tones-v2"
        let generatedSamples: Int64
        let passed = false
        let phase: Phase
        let processing: [String: Bool]
        let processingEvidence: MediaProcessingEvidence?
        let processingTimeline: [MediaProcessingTimeline.Entry]
        let processingTimelineDropped: Int
        let codecs: [String: String]
        let decoded: MediaAudioProbe.Observation
        let output: MediaAudioProbe.Observation
        let silenceWindows: [PCMSilenceWindows.Window]
        let teardown: MediaTeardownEvidence.Receipt?
        let startup: MediaStartupEvidence.Receipt
        let sdkAudioState: MediaSDKAudioState
      }
      let result = FailureResult(
        generatedSamples: hooks.generatedSamples, phase: phase, processing: processing,
        processingEvidence: processingEvidence,
        processingTimeline: hooks.processingTimeline.entries,
        processingTimelineDropped: hooks.processingTimeline.dropped,
        codecs: codecs, decoded: probe.observation(.decoded),
        output: probe.observation(.output), silenceWindows: silenceWindows,
        teardown: teardown.receipt(), startup: probe.startup.receipt(),
        sdkAudioState: sdkAudioState())
      try? JSONEncoder().encode(result).write(
        to: URL.documentsDirectory.appending(path: "media-result.json"))
    }
  }
#endif
