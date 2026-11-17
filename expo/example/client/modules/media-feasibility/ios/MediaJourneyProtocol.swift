#if DEBUG
  import Foundation

  /// SDK state read at failure; absence of the client or call stays explicit.
  struct MediaSDKAudioState: Codable {
    enum CallSource: String, Codable { case snapshot, endedEvent, unavailable }
    enum Status: String, Codable {
      case unavailable, ringing, previewing, dialing, connecting, connected, reconnecting, ended
    }
    enum Failure: String, Codable {
      case refused, atCapacity, notPlaced, media, audioActivationTimedOut, audioSession
      case audioRecoveryTimedOut, connectTimedOut, reconnectTimedOut, actionTimedOut, frameworkReset
      case server
    }
    struct CallObservation {
      let status: Status
      let failure: Failure?
      let source: CallSource
      let atMs: Double
    }
    /// Ended calls leave the live SDK snapshot; retain one actual terminal observation.
    struct CallHistory {
      private var lastEnded: CallObservation?
      mutating func recordEnded(failure: Failure?, atMs: Double) {
        lastEnded = CallObservation(
          status: .ended, failure: failure, source: .endedEvent, atMs: atMs)
      }
      func observation(snapshot: CallObservation?) -> CallObservation? { snapshot ?? lastEnded }
    }
    let clockID: UUID
    let observedAtMs: Double
    let isAudioActive: Bool?
    let callStatus: Status
    let callFailure: Failure?
    let callSource: CallSource
    let callObservedAtMs: Double?
  }

  struct MediaJourneyFixture: Decodable {
    let fixtureId: String
    let conversationId: String
    let initialVideo: Bool?
    init(fixtureId: String, conversationId: String, initialVideo: Bool? = nil) {
      self.fixtureId = fixtureId
      self.conversationId = conversationId
      self.initialVideo = initialVideo
    }
  }

  struct MediaJourneyCommand: Decodable {
    enum Operation: String, Decodable {
      case beginPhase, snapshot, mute, hold, video, armTeardown, end, close
    }
    let id: UUID
    let sessionId: UUID
    let fixtureId: String
    let conversationId: String
    let operation: Operation
    let phaseId: String?
    let frequencies: [Double]?
    let enabled: Bool?
    let videoSource: MediaSDKVideoEvidence.Source?
  }

  /// Validates the serialized example control boundary before it touches real call media.
  struct MediaJourneySession {
    enum Failure: Error { case invalidIdentity, staleCommand, invalidPhase, invalidArguments }
    let id = UUID()
    let fixture: MediaJourneyFixture
    private(set) var phaseId: String?
    private var commands: Set<UUID> = []
    private var phases: Set<String> = []
    private var terminalArmed = false
    init(fixture: MediaJourneyFixture) throws(Failure) {
      guard !fixture.fixtureId.isEmpty, fixture.fixtureId.count <= 128,
        !fixture.conversationId.isEmpty, fixture.conversationId.count <= 256
      else { throw .invalidIdentity }
      self.fixture = fixture
    }
    mutating func accept(_ command: MediaJourneyCommand) throws(Failure) {
      guard command.sessionId == id, command.fixtureId == fixture.fixtureId,
        command.conversationId == fixture.conversationId
      else { throw .invalidIdentity }
      // Covers commands at the 20 ms loop cadence throughout the 180 s journey budget.
      guard commands.count < 16_384, !commands.contains(command.id) else { throw .staleCommand }
      switch command.operation {
      case .beginPhase:
        guard let phase = command.phaseId, !phase.isEmpty, phase.count <= 4096,
          !terminalArmed, !phases.contains(phase), let frequencies = command.frequencies,
          frequencies.count == 12,
          frequencies.allSatisfy({ [650, 950, 1350, 1850].contains($0) })
        else { throw .invalidPhase }
        phaseId = phase
        phases.insert(phase)
      case .snapshot:
        guard let phaseId, command.phaseId == phaseId else { throw .invalidPhase }
      case .armTeardown:
        guard !terminalArmed, let phaseId, command.phaseId == phaseId else { throw .invalidPhase }
        terminalArmed = true
      case .mute, .hold:
        guard let phaseId, command.phaseId == phaseId else { throw .invalidPhase }
        guard command.enabled != nil else { throw .invalidArguments }
      case .video:
        guard !terminalArmed, let phaseId, command.phaseId == phaseId else { throw .invalidPhase }
        guard command.enabled != nil, command.videoSource != nil else { throw .invalidArguments }
      case .end:
        guard terminalArmed, let phaseId, command.phaseId == phaseId else { throw .invalidPhase }
      case .close:
        guard command.phaseId == phaseId else { throw .invalidPhase }
      }
      commands.insert(command.id)
    }
  }
#endif
