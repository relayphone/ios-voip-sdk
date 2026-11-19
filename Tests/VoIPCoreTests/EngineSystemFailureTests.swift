import Testing
import VoIPTesting

@testable import VoIPCore

@Suite struct EngineSystemFailureTests {
  @Test @VoIPActor func refusesOnlyTheFailedIncomingAdmission() {
    let rig = SystemFailureRig()
    rig.deliver(otherCallID, eventID: e1)
    rig.framework.presentationOutcome = nil
    rig.deliver(callID, eventID: e2)
    rig.framework.completeReports(of: callID, with: .refused(.systemFailed(admissionFailure)))

    #expect(rig.status(callID) == .ended(.failed(.systemFailed(admissionFailure))))
    #expect(rig.status(otherCallID) == .ringing)
    #expect(rig.reportsEnded.isEmpty)
    #expect(rig.ended == [callID])
  }

  @Test @VoIPActor func retainedEndWinsOverAdmissionFailure() {
    let rig = SystemFailureRig()
    rig.framework.presentationOutcome = nil
    rig.deliver(callID, eventID: e1)
    rig.engine.receive(.answeredElsewhere, for: callID, eventID: e2)
    rig.framework.completeReports(of: callID, with: .refused(.systemFailed(admissionFailure)))

    #expect(rig.status(callID) == .ended(.answeredElsewhere))
    #expect(rig.reportsEnded.isEmpty)
    #expect(rig.ended == [callID])
  }

  @Test(arguments: [false, true])
  @VoIPActor func localEndWaitsForTheAdmissionResult(admitted: Bool) throws {
    let rig = SystemFailureRig()
    rig.framework.presentationOutcome = nil
    let delivery = rig.deliver(callID, eventID: e1)
    let first = try rig.engine.end(callID)
    #expect(rig.status(callID) == .ended(.localEnded))
    #expect(rig.reportsEnded.isEmpty)

    let result: PresentationOutcome =
      admitted ? .presented : .refused(.systemFailed(admissionFailure))
    rig.framework.completeReports(of: callID, with: result)

    #expect(rig.status(callID) == .ended(.localEnded))
    #expect(try rig.engine.end(callID) == first)
    #expect(rig.reportsEnded == (admitted ? [callID] : []))
    #expect(rig.ended == [callID])
    #expect(rig.push.finished == [delivery])
  }

  @Test @VoIPActor func ignoresAnOldAdmissionFailureDuringANewReportForTheSameCall() throws {
    let rig = SystemFailureRig()
    rig.framework.presentationOutcome = nil
    let first = rig.deliver(callID, eventID: e1)
    let oldReport = try #require(rig.framework.takeReportCompletion(of: callID))
    rig.framework.send(.reset)
    #expect(rig.status(callID) == .ended(.failed(.frameworkReset)))
    rig.clock.advance(by: .seconds(2))
    let second = rig.deliver(callID, eventID: e2)
    oldReport(.refused(.systemFailed(admissionFailure)))
    #expect(rig.engine.phase(for: callID) == .reporting)
    #expect(rig.push.finished == [first])
    rig.framework.completeReports(of: callID, with: .presented)
    #expect(rig.status(callID) == .ringing)
    #expect(rig.push.finished == [first, second])
    #expect(rig.ended == [callID])
    #expect(rig.reportsEnded.isEmpty)
  }

  @Test(arguments: [VoIPConfiguration.OutgoingMedia.whenProvided, .duringPlacement])
  @VoIPActor func earlyConnectedDoesNotSurviveStartRefusal(
    policy: VoIPConfiguration.OutgoingMedia
  ) async throws {
    let rig = SystemFailureRig(outgoingMedia: policy)
    rig.deliver(otherCallID, eventID: e1)
    let complete = try await rig.placePendingStart()
    rig.engine.receive(.connected, for: callID, eventID: e2)
    if policy == .whenProvided { try rig.engine.provideMedia(callID) }
    #expect(rig.status(callID) == .dialing)
    #expect(rig.startResults.isEmpty)
    let detail = FrameworkError(domain: "native.start", code: 7)
    complete(.failure(.refused(detail)))

    let failure = SystemFailure(platform: .ios, operation: .start, diagnostic: .framework(detail))
    #expect(throws: ActionError.refused(detail)) { try rig.startResults.first?.get() }
    #expect(rig.startResults.count == 1)
    #expect(rig.status(callID) == .ended(.failed(.systemFailed(failure))))
    #expect(rig.status(otherCallID) == .ringing)
    #expect(rig.reportsEnded.isEmpty)
    #expect(rig.ended == [callID])
    #expect(
      rig.media.lifecycleRecords.contains { if case .release = $0 { true } else { false } }
        == (policy == .duringPlacement))
    #expect(!rig.framework.records.contains(.reportOutgoing(callID, connected: true)))
  }

  @Test @VoIPActor func localEndRejectsPendingStartBeforeLateFailure() async throws {
    let rig = SystemFailureRig()
    let complete = try await rig.placePendingStart()
    let receipt = try rig.engine.end(callID)
    #expect(throws: ActionError.notAllowed(.ended(.localEnded))) {
      try rig.startResults.first?.get()
    }
    #expect(rig.status(callID) == .ended(.localEnded))
    complete(.failure(.refused(nil)))
    #expect(rig.startResults.count == 1)
    #expect(try rig.engine.end(callID) == receipt)
    #expect(rig.ended == [callID])
    #expect(rig.reportsEnded.isEmpty)
    rig.clock.advance(by: .seconds(2))
    _ = try await rig.placePendingStart()
    #expect(rig.status(callID) == .dialing)
    _ = try rig.engine.end(callID)
  }

  @Test @VoIPActor func lateAdmissionAfterRemoteEndRequestsRemoval() async throws {
    let rig = SystemFailureRig()
    let complete = try await rig.placePendingStart()
    try rig.engine.provideMedia(callID)
    rig.engine.receive(.endedRemotely, for: callID, eventID: e1)
    #expect(throws: ActionError.notAllowed(.ended(.endedRemotely))) {
      try rig.startResults.first?.get()
    }
    #expect(rig.reportsEnded.isEmpty)

    complete(.success(()))
    #expect(rig.status(callID) == .ended(.endedRemotely))
    #expect(rig.startResults.count == 1)
    #expect(rig.framework.records.last == .reportEnded(callID, .endedRemotely))
    #expect(rig.ended == [callID])
    #expect(rig.media.records.isEmpty)
  }

  @Test @VoIPActor func bufferedAliasEndRejectsPendingStart() async throws {
    let rig = SystemFailureRig()
    let alias = try #require(RemoteCallID(rawValue: "pending-start"))
    rig.engine.receive(.answeredElsewhere, forRemote: alias, eventID: e1)
    let complete = try await rig.placePendingStart()
    try rig.engine.bindRemote(alias, to: callID)

    #expect(rig.status(callID) == .ended(.answeredElsewhere))
    #expect(throws: ActionError.notAllowed(.ended(.answeredElsewhere))) {
      try rig.startResults.first?.get()
    }
    #expect(rig.reportsEnded.isEmpty)
    complete(.success(()))
    #expect(rig.startResults.count == 1)
    #expect(rig.framework.records.last == .reportEnded(callID, .answeredElsewhere))
    #expect(rig.ended == [callID])
  }

  @Test(arguments: [false, true])
  @VoIPActor func ignoresOldStartResultDuringReplacement(admitted: Bool) async throws {
    let rig = SystemFailureRig()
    let oldStart = try await rig.placePendingStart()
    rig.framework.send(.reset)
    rig.clock.advance(by: .seconds(2))
    let replacement = try await rig.placePendingStart()
    rig.engine.receive(.connected, for: callID, eventID: e1)
    try rig.engine.provideMedia(callID)
    oldStart(admitted ? .success(()) : .failure(.refused(nil)))
    #expect(rig.status(callID) == .dialing)
    #expect(rig.startResults.count == 1)
    #expect(rig.reportsEnded.isEmpty)
    #expect(rig.media.records.isEmpty)

    replacement(.success(()))
    await rig.engine.synchronize()
    #expect(rig.status(callID) == .connected)
    #expect(rig.startResults.count == 2)
    try rig.startResults.last?.get()
    #expect(rig.ended == [callID])
  }

  @Test(arguments: [false, true])
  @VoIPActor func noAnswerDeadlineWinsOverStartResult(admitted: Bool) async throws {
    let rig = SystemFailureRig()
    let complete = try await rig.placePendingStart()
    rig.clock.advance(by: Deadlines().ring)
    complete(admitted ? .success(()) : .failure(.refused(nil)))

    #expect(rig.status(callID) == .ended(.unanswered))
    #expect(throws: ActionError.notAllowed(.ended(.unanswered))) {
      try rig.startResults.first?.get()
    }
    #expect(rig.startResults.count == 1)
    #expect(rig.reportsEnded == (admitted ? [callID] : []))
  }

  @Test @VoIPActor func placementDeadlineWinsOverConfirmation() throws {
    let rig = SystemFailureRig()
    rig.beginStart()
    rig.clock.advance(by: Deadlines().placement)
    rig.engine.confirmPlaced(callID)

    #expect(rig.status(callID) == .ended(.failed(.notPlaced)))
    #expect(rig.framework.records.isEmpty)
    #expect(throws: ActionError.notAllowed(.ended(.failed(.notPlaced)))) {
      try rig.startResults.first?.get()
    }
  }

  @Test(arguments: [false, true])
  @VoIPActor func replaysDeferredProgressInReceiveOrder(connectedFirst: Bool) async throws {
    let rig = SystemFailureRig()
    let complete = try await rig.placePendingStart()
    if connectedFirst { rig.engine.receive(.connected, for: callID, eventID: e1) }
    try rig.engine.provideMedia(callID)
    rig.engine.receive(.connected, for: callID, eventID: e2)
    try rig.engine.provideMedia(callID)
    #expect(rig.status(callID) == .dialing)
    #expect(rig.media.records.isEmpty)

    complete(.success(()))
    await rig.engine.synchronize()
    let prepared = rig.media.records.compactMap { record -> CallStatus? in
      if case .prepare(let call) = record { call.status } else { nil }
    }
    #expect(prepared == [connectedFirst ? .connecting : .dialing])
    #expect(rig.status(callID) == .connected)
    #expect(rig.startResults.count == 1)
    try rig.startResults.first?.get()
  }
}

private let admissionFailure = SystemFailure(
  platform: .ios, operation: .admission, diagnostic: .code(7))

@VoIPActor
private final class SystemFailureRig {
  let framework = FakeCallingFramework()
  let push = FakePushSource()
  let media = FakeMedia()
  let clock = TestClock()
  let engine: SpecEngine
  private let log = Log()

  @VoIPActor private final class Log {
    var events: [CallEvent] = []
    var startResults: [Result<Void, ActionError>] = []
  }

  init(outgoingMedia: VoIPConfiguration.OutgoingMedia = .whenProvided) {
    engine = SpecEngine(
      framework: framework, media: media, push: push,
      configuration: VoIPConfiguration(retention: .seconds(1), outgoingMedia: outgoingMedia),
      clock: clock,
      observe: { [log] in log.events.append($0) })
  }

  var startResults: [Result<Void, ActionError>] { log.startResults }

  func beginStart() {
    engine.start(outgoing) { [log] in log.startResults.append($0) }
  }

  func placePendingStart() async throws -> @VoIPActor (Result<Void, ActionError>) -> Void {
    framework.requestResult = .accept
    beginStart()
    engine.confirmPlaced(callID)
    await engine.synchronize()
    return try #require(framework.takeStartCompletion(of: callID))
  }

  @discardableResult
  func deliver(_ id: CallID, eventID: EventID) -> VoIPPush {
    let delivery = VoIPPush.incoming(incoming(id, .ring), eventID: eventID)
    push.deliver(delivery)
    return delivery
  }

  func status(_ id: CallID) -> CallStatus? {
    engine.calls.first(where: { $0.id == id })?.status
  }

  var ended: [CallID] {
    log.events.compactMap { if case .ended(let call) = $0 { call.id } else { nil } }
  }

  var reportsEnded: [CallID] {
    framework.records.compactMap { if case .reportEnded(let id, _) = $0 { id } else { nil } }
  }
}
