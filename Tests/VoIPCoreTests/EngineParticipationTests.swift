import Testing
import VoIPTesting

@testable import VoIPCore

@Suite(.timeLimit(.minutes(1)))
@VoIPActor
struct EngineParticipationTests {
  @Test func twoLinesRingAndHoldingTheFirstLetsTheSecondAnswer() async throws {
    let rig = ParticipationRig()
    defer { rig.engine.close() }
    let first = try callingLine("personal", label: "Personal")
    let second = try callingLine("work", label: "Work")
    rig.invite(callID, on: first)
    rig.invite(otherCallID, on: second)
    #expect(rig.engine.calls.count { $0.status == .ringing } == 2)
    #expect(rig.call(callID)?.line == first)
    #expect(rig.call(otherCallID)?.line == second)
    #expect(rig.engine.participating.isEmpty)

    rig.invite(otherCallID, on: first, eventID: e3)
    #expect(rig.call(otherCallID)?.line == second)

    try await rig.engine.request(.answer(callID))
    await rig.engine.synchronize()
    rig.engine.receive(.connected, for: callID, eventID: e1)
    #expect(rig.call(callID)?.status == .connected)
    let previewID = CallID(rawValue: "waiting-preview")
    rig.invite(previewID, on: second, policy: .init(incoming: .preview))
    let recordsBeforeRefusal = rig.framework.records
    await #expect(throws: ActionError.notAllowed(.ringing)) {
      try await rig.engine.request(.answer(otherCallID))
    }
    await #expect(throws: ActionError.notAllowed(.previewing(.policy))) {
      try await rig.engine.request(.join(previewID))
    }
    let outgoing = OutgoingCall(
      id: CallID(rawValue: "blocked-start"), parties: [alice], line: second)
    await #expect(throws: ActionError.notAllowed(.dialing)) {
      try await rig.engine.request(.start(outgoing))
    }
    #expect(rig.framework.records == recordsBeforeRefusal)
    #expect(rig.call(otherCallID)?.status == .ringing)
    #expect(rig.call(previewID)?.status == .previewing(.policy))
    #expect(rig.call(outgoing.id) == nil)
    #expect(rig.engine.participating == [callID])

    try await rig.engine.request(.hold(callID, onHold: true))
    #expect(rig.call(callID)?.isOnHold == true)
    #expect(rig.engine.participating.isEmpty)
    try await rig.engine.request(.answer(otherCallID))
    await rig.engine.synchronize()
    #expect(rig.call(otherCallID)?.status == .connecting)
    #expect(rig.engine.participating == [otherCallID])
    await #expect(throws: ActionError.notAllowed(.connected)) {
      try await rig.engine.request(.hold(callID, onHold: false))
    }

    _ = try rig.engine.end(otherCallID)
    rig.framework.requestResult = .accept
    try await rig.engine.request(.hold(callID, onHold: false))
    #expect(rig.call(callID)?.isOnHold == true)
    #expect(rig.engine.participating == [callID])
    rig.framework.perform(.hold(callID, onHold: false))
    #expect(rig.call(callID)?.isOnHold == false)
    #expect(rig.engine.participating == [callID])
  }

  @Test func appAnswerReservesUntilItsNativeReceiptOrRequestFailure() async throws {
    let rig = ParticipationRig()
    defer { rig.engine.close() }
    rig.invite(callID, on: try callingLine("personal", label: "Personal"))
    rig.invite(otherCallID, on: try callingLine("work", label: "Work"))

    rig.framework.requestResult = .refuse(.refused(nil))
    await #expect(throws: ActionError.refused(nil)) {
      try await rig.engine.request(.answer(callID))
    }
    #expect(rig.call(callID)?.status == .ringing)
    #expect(rig.engine.participating.isEmpty)

    rig.framework.requestResult = .accept
    try await rig.engine.request(.answer(otherCallID))
    #expect(rig.call(otherCallID)?.status == .ringing)
    #expect(rig.engine.participating == [otherCallID])
    let recordsWhileAwaitingReceipt = rig.framework.records
    await #expect(throws: ActionError.notAllowed(.ringing)) {
      try await rig.engine.request(.answer(callID))
    }
    #expect(rig.framework.records == recordsWhileAwaitingReceipt)
    rig.framework.perform(.answer(otherCallID))
    await rig.engine.synchronize()
    #expect(rig.call(otherCallID)?.status == .connecting)
    #expect(rig.engine.participating == [otherCallID])
  }

  @Test func startReservesBeforeNativeAdmissionAndPlacementFailureReleasesTheSlot() async throws {
    let rig = ParticipationRig()
    defer { rig.engine.close() }
    let personal = try callingLine("personal", label: "Personal")
    let work = try callingLine("work", label: "Work")
    rig.invite(otherCallID, on: work)
    let outgoing = OutgoingCall(id: callID, parties: [alice], line: personal)
    var placement: Result<Void, ActionError>?
    rig.engine.start(outgoing) { placement = $0 }
    #expect(rig.engine.participating == [callID])
    #expect(rig.call(callID)?.line == personal)
    #expect(placement == nil)

    let recordsBeforeRefusal = rig.framework.records
    await #expect(throws: ActionError.notAllowed(.ringing)) {
      try await rig.engine.request(.answer(otherCallID))
    }
    #expect(rig.framework.records == recordsBeforeRefusal)
    #expect(rig.call(otherCallID)?.status == .ringing)

    rig.clock.advance(by: Deadlines().placement)
    await rig.engine.synchronize()
    guard case .failure(.notAllowed(.ended(.failed(.notPlaced)))) = placement else {
      Issue.record("Expected Start to fail when placement expires")
      return
    }
    #expect(rig.engine.participating.isEmpty)
    try await rig.engine.request(.answer(otherCallID))
    await rig.engine.synchronize()
    #expect(rig.engine.participating == [otherCallID])
  }

  @Test func aPreviewJoinReservesUntilPlacementFails() async throws {
    let rig = ParticipationRig()
    defer { rig.engine.close() }
    let personal = try callingLine("personal", label: "Personal")
    let work = try callingLine("work", label: "Work")
    rig.invite(callID, on: personal, policy: .init(incoming: .preview))
    rig.invite(otherCallID, on: work)

    try await rig.engine.request(.join(callID))
    rig.framework.perform(.hold(callID, onHold: true))
    #expect(rig.engine.participating == [callID])
    await #expect(throws: ActionError.notAllowed(.ringing)) {
      try await rig.engine.request(.answer(otherCallID))
    }

    rig.clock.advance(by: Deadlines().placement)
    await rig.engine.synchronize()
    #expect(rig.call(callID)?.status == .previewing(.policy))
    #expect(rig.call(callID)?.line == personal)
    #expect(rig.engine.participating.isEmpty)
    try await rig.engine.request(.answer(otherCallID))
    await rig.engine.synchronize()
    #expect(rig.engine.participating == [otherCallID])
  }
}

func callingLine(_ id: String, label: String) throws -> CallingLine {
  CallingLine(
    accountID: try #require(AccountID(rawValue: "account-a")),
    id: try #require(LineID(rawValue: id)), label: label)
}

@VoIPActor
private final class ParticipationRig {
  let framework = FakeCallingFramework()
  let push = FakePushSource()
  let clock = TestClock()
  let engine: SpecEngine

  init() {
    engine = SpecEngine(
      framework: framework, media: FakeMedia(), push: push, configuration: VoIPConfiguration(),
      clock: clock, observe: { _ in })
  }

  func invite(
    _ id: CallID, on line: CallingLine, eventID: EventID? = nil, policy: PresentationPolicy? = nil
  ) {
    push.deliver(
      .incoming(
        IncomingCall(id: id, parties: [alice], presentationPolicy: policy, line: line),
        eventID: eventID ?? EventID(rawValue: id.rawValue)))
  }

  func call(_ id: CallID) -> Call? { engine.calls.first { $0.id == id } }
}
