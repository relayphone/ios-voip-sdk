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
    func prepare(_ call: Call) async throws { try await bridge.prepare(call.id) }
    func activate() { commands.yield(.activate) }
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
      let processingTimeline: [MediaProcessingTimeline.Entry]
      let processingTimelineDropped: Int
      let codecs: [String: String]
      let silenceWindows: [PCMSilenceWindows.Window]
    }
    nonisolated let commands: AsyncStream<AudioCommand>.Continuation
    let probe = MediaAudioProbe(captureDuration: .seconds(10))
    let fixture: Fixture
    let room = Room()
    nonisolated let packetEvents = PacketEvents()
    var packets: Task<Void, Never>?
    let decoder: DecodedAudioProbe
    let hooks: MarkerAudioEngine
    var events: Task<Void, Never>?
    var audio: Task<Void, Never>?
    var observer: Task<Void, Never>?
    var publicationMuted = false
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
    var codecs: [String: String] = [:]
    var silenceWindows: [PCMSilenceWindows.Window] = []
    var localTrack: LocalAudioTrack?
    var remoteTrack: RemoteAudioTrack?
    init(_ fixture: Fixture) {
      self.fixture = fixture
      decoder = DecodedAudioProbe(probe: probe)
      hooks = MarkerAudioEngine(probe: probe, frequencies: fixture.uplinkFrequencies)
      let stream = AsyncStream<AudioCommand>.makeStream()
      commands = stream.continuation
      super.init()
      audio = Task { [weak self] in
        for await command in stream.stream {
          guard let self else { return }
          do {
            switch command {
            case .activate:
              probe.beginWindow()
              hooks.processingTimeline.record(.engineAvailabilityApplying)
              try AudioManager.shared.setEngineAvailability(.default)
              hooks.processingTimeline.record(
                .engineAvailabilityApplied, engineRunning: AudioManager.shared.isEngineRunning)
              active = true
            case .deactivate:
              try AudioManager.shared.setEngineAvailability(.none)
              active = false
            case .release:
              packets?.cancel()
              packets = nil
              await room.disconnect()
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
      room.add(delegate: self)
      try await room.connect(url: fixture.url, token: fixture.token)
      hooks.processingTimeline.record(.captureOptionsApplying)
      let publication = try await room.localParticipant.setMicrophone(
        enabled: true,
        captureOptions: MarkerAudioEngine.syntheticCaptureOptions)
      hooks.processingTimeline.record(.captureOptionsApplied)
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
        guard let self, let track = publication.track as? RemoteAudioTrack else { return }
        decoder.attach(to: track)
        remoteTrack = track
        await track.set(reportStatistics: true)
      }
    }
    func attach(to client: VoIPClient) {
      let stream = client.events()
      observer = Task { [weak self] in
        for await event in stream {
          guard let self else { return }
          if case .performed(.mute(_, let muted), _) = event {
            do {
              try await room.localParticipant.setMicrophone(enabled: !muted)
              publicationMuted = muted
            } catch { fail() }
          }
        }
      }
      events = Task { [weak self, weak client] in
        guard let self, let client else { return }
        do {
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
          guard state.aec.requested != .unavailable, state.ns.requested != .unavailable,
            state.agc.requested != .unavailable
          else {
            throw MediaAudioProbe.Failure.signalMissing(.decoded)
          }
          processing = [
            "aecRequested": state.aec.requested == .enabled,
            "aecActive": state.aec.active,
            "nsRequested": state.ns.requested == .enabled,
            "nsActive": state.ns.active,
            "agcRequested": state.agc.requested == .enabled,
            "agcActive": state.agc.active,
          ]
          let expected = [
            "aec": false,
            "ns": false,
            "agc": true,
          ]
          for (effect, enabled) in expected {
            guard processing[effect + "Requested"] == enabled,
              processing[effect + "Active"] == enabled
            else {
              throw MediaAudioProbe.Failure.signalMissing(.decoded)
            }
          }
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
          try await client.request(.end(incoming.id))
          phase = .teardown
          try await until { self.released && !self.active }
          guard !failed else { return }
          let result = Result(
            generatedSamples: hooks.generatedSamples, passed: true, decoded: decoded,
            output: output,
            mutedOutput: mutedOutput, missingTapCaught: caught,
            inactiveEngineStayedStopped: inactiveEngineStayedStopped, processing: processing,
            processingTimeline: hooks.processingTimeline.entries,
            processingTimelineDropped: hooks.processingTimeline.dropped,
            codecs: codecs, silenceWindows: silenceWindows)
          try JSONEncoder().encode(result).write(
            to: URL.documentsDirectory.appending(path: "media-result.json"))

        } catch { fail() }
      }
    }
    private func until(_ condition: () -> Bool) async throws {
      let clock = ContinuousClock()
      let deadline = ContinuousClock().now + .seconds(10)
      while !condition() {
        if clock.now >= deadline { throw MediaAudioProbe.Failure.noFrames(.output) }
        try await clock.sleep(for: .milliseconds(20))
      }
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
    private func fail() {
      guard !failed else { return }
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
        let processingTimeline: [MediaProcessingTimeline.Entry]
        let processingTimelineDropped: Int
        let codecs: [String: String]
        let decoded: MediaAudioProbe.Observation
        let output: MediaAudioProbe.Observation
        let silenceWindows: [PCMSilenceWindows.Window]
      }
      let result = FailureResult(
        generatedSamples: hooks.generatedSamples, phase: phase, processing: processing,
        processingTimeline: hooks.processingTimeline.entries,
        processingTimelineDropped: hooks.processingTimeline.dropped,
        codecs: codecs, decoded: probe.observation(.decoded),
        output: probe.observation(.output), silenceWindows: silenceWindows)
      try? JSONEncoder().encode(result).write(
        to: URL.documentsDirectory.appending(path: "media-result.json"))
    }
  }
#endif
