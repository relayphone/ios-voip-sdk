import Foundation
import Testing

@testable import MediaJourneyProtocol

struct ProtocolTests {
  @Test func endedCallFailureSurvivesRemovalFromTheLiveSDKSnapshot() {
    var history = MediaSDKAudioState.CallHistory()
    #expect(history.observation(snapshot: nil) == nil)
    let live = MediaSDKAudioState.CallObservation(
      status: .connecting, failure: nil, source: .snapshot, atMs: 50)
    #expect(history.observation(snapshot: live)?.status == .connecting)
    history.recordEnded(failure: .audioActivationTimedOut, atMs: 100)
    let terminal = history.observation(snapshot: nil)
    #expect(terminal?.status == .ended)
    #expect(terminal?.failure == .audioActivationTimedOut)
    #expect(terminal?.source == .endedEvent)
    #expect(terminal?.atMs == 100)
    #expect(history.observation(snapshot: live)?.source == .snapshot)
    history.recordEnded(failure: .media, atMs: 200)
    #expect(history.observation(snapshot: nil)?.failure == .media)
    #expect(terminal?.failure == .audioActivationTimedOut)
  }
  @Test func failureAudioStatePreservesMissingClientAndTypedCallFailure() throws {
    let clock = UUID()
    for active: Bool? in [nil, false, true] {
      let receipt = MediaSDKAudioState(
        clockID: clock, observedAtMs: 120, isAudioActive: active,
        callStatus: .ended, callFailure: .audioActivationTimedOut,
        callSource: .endedEvent, callObservedAtMs: 100)
      let decoded = try JSONDecoder().decode(
        MediaSDKAudioState.self, from: JSONEncoder().encode(receipt))
      #expect(decoded.clockID == clock)
      #expect(decoded.observedAtMs == 120)
      #expect(decoded.isAudioActive == active)
      #expect(decoded.callStatus == .ended)
      #expect(decoded.callFailure == .audioActivationTimedOut)
      #expect(decoded.callSource == .endedEvent)
      #expect(decoded.callObservedAtMs == 100)
    }
  }
  func command(
    _ session: MediaJourneySession, _ operation: MediaJourneyCommand.Operation,
    phase: String? = nil, frequencies: [Double]? = nil, enabled: Bool? = nil,
    sessionID: UUID? = nil, videoSource: MediaSDKVideoEvidence.Source? = nil
  ) -> MediaJourneyCommand {
    MediaJourneyCommand(
      id: UUID(), sessionId: sessionID ?? session.id,
      fixtureId: session.fixture.fixtureId, conversationId: session.fixture.conversationId,
      operation: operation, phaseId: phase, frequencies: frequencies, enabled: enabled,
      videoSource: videoSource)
  }
  @Test func rejectsForeignSessionReplayAndStalePhasesBeforeMediaControl() throws {
    var session = try MediaJourneySession(
      fixture: MediaJourneyFixture(fixtureId: "fixture", conversationId: "call"))
    let frequencies = Array(repeating: 650.0, count: 12)
    #expect(throws: MediaJourneySession.Failure.self) {
      try session.accept(
        command(session, .beginPhase, phase: "one", frequencies: frequencies, sessionID: UUID()))
    }
    #expect(session.phaseId == nil)
    let first = command(session, .beginPhase, phase: "one", frequencies: frequencies)
    try session.accept(first)
    #expect(throws: MediaJourneySession.Failure.self) { try session.accept(first) }
    try session.accept(command(session, .beginPhase, phase: "two", frequencies: frequencies))
    #expect(throws: MediaJourneySession.Failure.self) {
      try session.accept(command(session, .snapshot, phase: "one"))
    }
    #expect(throws: MediaJourneySession.Failure.self) {
      try session.accept(command(session, .beginPhase, phase: "one", frequencies: frequencies))
    }
    #expect(session.phaseId == "two")
  }
  @Test func terminalArmingCannotResetTheAttemptOrRenewMediaPhases() throws {
    var session = try MediaJourneySession(
      fixture: MediaJourneyFixture(fixtureId: "fixture", conversationId: "call"))
    #expect(throws: MediaJourneySession.Failure.self) {
      try session.accept(command(session, .end, phase: "live"))
    }
    try session.accept(
      command(session, .beginPhase, phase: "live", frequencies: Array(repeating: 950, count: 12)))
    try session.accept(command(session, .captureAudio, phase: "live"))
    try session.accept(command(session, .armTeardown, phase: "live"))
    #expect(throws: MediaJourneySession.Failure.self) {
      try session.accept(command(session, .armTeardown, phase: "live"))
    }
    #expect(throws: MediaJourneySession.Failure.self) {
      try session.accept(
        command(
          session, .beginPhase, phase: "replayed", frequencies: Array(repeating: 650, count: 12)))
    }
    try session.accept(command(session, .snapshot, phase: "live"))
    #expect(throws: MediaJourneySession.Failure.invalidPhase) {
      try session.accept(command(session, .audioSnapshot, phase: "stale"))
    }
    try session.accept(command(session, .audioSnapshot, phase: "live"))
    #expect(throws: MediaJourneySession.Failure.invalidPhase) {
      try session.accept(command(session, .captureAudio, phase: "live"))
    }
    try session.accept(command(session, .end, phase: "live"))
  }
  @Test func snapshotPollingRetainsReplayProtectionForTheFullJourneyBudget() throws {
    var session = try MediaJourneySession(
      fixture: MediaJourneyFixture(fixtureId: "fixture", conversationId: "call"))
    try session.accept(
      command(session, .beginPhase, phase: "live", frequencies: Array(repeating: 650, count: 12)))
    let first = command(session, .snapshot, phase: "live")
    try session.accept(first)
    for _ in 0..<9000 {
      try session.accept(command(session, .snapshot, phase: "live"))
    }
    #expect(throws: MediaJourneySession.Failure.self) { try session.accept(first) }
    try session.accept(command(session, .armTeardown, phase: "live"))
    try session.accept(command(session, .end, phase: "live"))
  }
  @Test func mediaControlsRejectMissingAndObsoletePhaseIdentities() throws {
    var session = try MediaJourneySession(
      fixture: MediaJourneyFixture(fixtureId: "fixture", conversationId: "call"))
    for phase in ["old", "current"] {
      try session.accept(
        command(session, .beginPhase, phase: phase, frequencies: Array(repeating: 650, count: 12)))
    }
    try session.accept(command(session, .armTeardown, phase: "current"))
    for operation in [MediaJourneyCommand.Operation.mute, .hold, .end, .close] {
      for stale: String? in [nil, "old"] {
        #expect(throws: MediaJourneySession.Failure.self) {
          try session.accept(command(session, operation, phase: stale, enabled: true))
        }
      }
      try session.accept(command(session, operation, phase: "current", enabled: true))
    }
  }
  @Test func invalidFrequenciesAndMissingActionValuesAreRejected() throws {
    var session = try MediaJourneySession(
      fixture: MediaJourneyFixture(fixtureId: "fixture", conversationId: "call"))
    for values in [[], Array(repeating: 400.0, count: 12), Array(repeating: 650.0, count: 11)] {
      #expect(throws: MediaJourneySession.Failure.self) {
        try session.accept(command(session, .beginPhase, phase: "bad", frequencies: values))
      }
    }
    try session.accept(
      command(session, .beginPhase, phase: "live", frequencies: Array(repeating: 650, count: 12)))
    for action in [MediaJourneyCommand.Operation.mute, .hold] {
      #expect(throws: MediaJourneySession.Failure.self) {
        try session.accept(command(session, action, phase: "live"))
      }
      try session.accept(command(session, action, phase: "live", enabled: true))
    }
    let encoded = """
      {"id":"\(UUID())","sessionId":"\(session.id)","fixtureId":"fixture","conversationId":"call","operation":"invented"}
      """
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(MediaJourneyCommand.self, from: Data(encoded.utf8))
    }
  }
}
