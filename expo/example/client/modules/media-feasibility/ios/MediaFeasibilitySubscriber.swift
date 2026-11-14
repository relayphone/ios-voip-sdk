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
  import VoIPConversations

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
    func prepare(_ call: Call) async throws { try await bridge.prepare() }
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
      let codecs: [String: String]
    }
    nonisolated let commands: AsyncStream<AudioCommand>.Continuation
    let probe = MediaAudioProbe()
    let fixture: Fixture
    let room = Room()
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
    var savedDuplex = false
    var processing: [String: Bool] = [:]
    var codecs: [String: String] = [:]
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
              try AudioManager.shared.setEngineAvailability(.default)
              active = true
            case .deactivate:
              try AudioManager.shared.setEngineAvailability(.none)
              active = false
            case .release:
              await room.disconnect()
              released = true
            }
            if released && !active { commands.finish() }
          } catch { fail() }
        }
        await self?.room.disconnect()
      }
    }
    func prepare() async throws {
      let manager = AudioManager.shared
      manager.audioSession.isAutomaticConfigurationEnabled = false
      manager.set(engineObservers: [manager.audioSession, manager.mixer, hooks])
      try manager.setEngineAvailability(.none)
      room.add(delegate: self)
      try await room.connect(url: fixture.url, token: fixture.token)
      let publication = try await room.localParticipant.setMicrophone(
        enabled: true,
        captureOptions: MarkerAudioEngine.syntheticCaptureOptions)
      localTrack = publication?.track as? LocalAudioTrack
      await localTrack?.set(reportStatistics: true)
      inactiveEngineStayedStopped =
        !manager.isEngineRunning && probe.observation(.output).samples == 0
      guard inactiveEngineStayedStopped else { throw MediaAudioProbe.Failure.audioLeaked(.output) }
    }
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
          let party = Party(handle: try Handle(kind: .generic, value: "media-peer"))
          let incoming = IncomingCall(id: CallID(rawValue: "media-example"), parties: [party])
          _ = await client.report(incoming)
          try await client.request(.answer(incoming.id))
          phase = .duplex
          try await until {
            self.probe.observation(.output).frameSeconds >= 3
              && self.probe.observation(.decoded).frameSeconds >= 3
          }
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
          let state = AudioManager.shared.audioProcessingState
          guard state.echoCancellation.requested != nil, state.noiseSuppression.requested != nil,
            state.autoGainControl.requested != nil
          else {
            throw MediaAudioProbe.Failure.signalMissing(.decoded)
          }
          processing = [
            "aecRequested": state.echoCancellation.requested?.isEnabled == true,
            "aecActive": state.echoCancellation.software.isActive,
            "nsRequested": state.noiseSuppression.requested?.isEnabled == true,
            "nsActive": state.noiseSuppression.software.isActive,
            "agcRequested": state.autoGainControl.requested?.isEnabled == true,
            "agcActive": state.autoGainControl.software.isActive,
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
          try await Task.sleep(for: .seconds(1))
          try probe.expectAudio(.decoded)
          try probe.expectSilence(.output, for: .seconds(1))
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
            codecs: codecs)
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
    private func saveDuplex() {
      guard !savedDuplex else { return }
      for stage in [MediaAudioProbe.Stage.decoded, .output] {
        try? JSONEncoder().encode(probe.capture(stage)).write(
          to: URL.documentsDirectory.appending(path: "media-" + stage.rawValue + ".json"))
      }
      savedDuplex = true
    }
    private func fail() {
      guard !failed else { return }
      failed = true
      saveDuplex()
      struct FailureResult: Encodable {
        let profile = "tones-v2"
        let generatedSamples: Int64
        let passed = false
        let phase: Phase
        let processing: [String: Bool]
        let codecs: [String: String]
        let decoded: MediaAudioProbe.Observation
        let output: MediaAudioProbe.Observation
      }
      let result = FailureResult(
        generatedSamples: hooks.generatedSamples, phase: phase, processing: processing,
        codecs: codecs, decoded: probe.observation(.decoded),
        output: probe.observation(.output))
      try? JSONEncoder().encode(result).write(
        to: URL.documentsDirectory.appending(path: "media-result.json"))
    }
  }
#endif
