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

  @Test(arguments: [false, true])
  @VoIPActor func refusesOnlyTheFailedStartAttempt(placed: Bool) async throws {
    let rig = SystemFailureRig()
    rig.deliver(otherCallID, eventID: e1)
    let detail = FrameworkError(domain: "native.start", code: 7)
    let failure = SystemFailure(
      platform: .android, operation: .start, diagnostic: .framework(detail))
    rig.framework.platform = .android
    rig.framework.requestHandler = { action throws(ActionError) in
      rig.framework.perform(action)
      if placed {
        rig.engine.confirmPlaced(action.callID)
        await rig.engine.synchronize()
      }
      throw .refused(detail)
    }
    defer { rig.framework.requestHandler = nil }

    await #expect(throws: ActionError.refused(detail)) {
      try await rig.engine.request(startAction)
    }
    let start = try #require(rig.framework.sentEvents.last)
    guard case .perform(let id, .start) = start else {
      Issue.record("Expected the system to deliver Start")
      return
    }
    #expect(rig.framework.records.contains(placed ? .fulfill(id) : .fail(id)))
    #expect(!rig.framework.records.contains(placed ? .fail(id) : .fulfill(id)))
    #expect(rig.status(callID) == .ended(.failed(.systemFailed(failure))))
    #expect(rig.status(otherCallID) == .ringing)
    #expect(rig.reportsEnded.isEmpty)
    #expect(rig.ended == [callID])
    #expect(
      rig.media.lifecycleRecords.contains { if case .release = $0 { true } else { false } }
        == placed)
  }

  @Test @VoIPActor func ignoresAnOldStartFailureDuringANewStartForTheSameCall() async throws {
    let rig = SystemFailureRig()
    rig.framework.requestHandler = { action throws(ActionError) in
      _ = try rig.engine.end(action.callID)
      rig.clock.advance(by: .seconds(2))
      rig.framework.requestHandler = nil
      try await rig.engine.request(action)
      throw .refused(nil)
    }

    await #expect(throws: ActionError.refused(nil)) {
      try await rig.engine.request(startAction)
    }
    #expect(rig.engine.phase(for: callID) == .placing)
    #expect(rig.ended == [callID])
    #expect(rig.reportsEnded == [callID])
    let performed = try #require(rig.framework.sentEvents.last)
    guard case .perform(let id, .start) = performed else {
      Issue.record("Expected the system to deliver the replacement Start")
      return
    }
    #expect(!rig.framework.records.contains(.fail(id)))
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
  }

  init() {
    engine = SpecEngine(
      framework: framework, media: media, push: push,
      configuration: VoIPConfiguration(retention: .seconds(1)), clock: clock,
      observe: { [log] in log.events.append($0) })
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
