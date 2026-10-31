import Foundation
import Testing

@testable import CKSimInspector

/// How the Inspector presents LiveCommunicationKit calls, following the iPhone 13 measurements.
struct LCKProjectionTests {
  private let waiting: RuntimeEvent

  init() throws {
    waiting = try call(
      1,
      [
        "uuid": "waiting", "apiKind": "livecommunicationkit", "ringing": true, "capabilities": [],
        "availableSystemChoices": ["end-and-accept", "decline", "hold-and-accept"],
      ])
  }

  @Test func systemChoicesComeOnlyFromTheReportedChoices() throws {
    #expect(
      InspectorLCKProjection.systemChoices(for: waiting) == [
        "end-and-accept", "decline", "hold-and-accept",
      ], "Capabilities must not remove an observed Hold & Accept")
    let full = try call(
      2,
      [
        "apiKind": "livecommunicationkit",
        "availableSystemChoices": ["end-and-accept", "decline", "end-held-and-accept"],
      ])
    #expect(
      InspectorLCKProjection.systemChoices(for: full) == [
        "end-and-accept", "decline", "end-held-and-accept",
      ])
    let missing = try call(
      3, ["apiKind": "livecommunicationkit", "capabilities": ["pausing", "merging"]])
    #expect(
      InspectorLCKProjection.systemChoices(for: missing) == nil,
      "Missing choices aren't invented from capabilities or counts")
    let unknown = try call(
      4,
      [
        "apiKind": "livecommunicationkit",
        "availableSystemChoices": ["merge", "answer", "answer", "swap"],
      ])
    #expect(
      InspectorLCKProjection.systemChoices(for: unknown) == ["answer"],
      "The system's inert Merge control is never offered")
    let callKit = try call(5, ["apiKind": "callkit", "availableSystemChoices": ["answer"]])
    #expect(InspectorLCKProjection.systemChoices(for: callKit) == nil)
  }

  @Test(
    arguments: [
      (["connected": true], "joined"), (["held": true], "paused"), (["ended": true], "left"),
    ] as [([String: Bool], String)])
  func conversationStatesUseLiveCommunicationKitNames(fields: [String: Bool], status: String)
    throws
  {
    var values: [String: Any] = ["apiKind": "livecommunicationkit"]
    values.merge(fields) { _, new in new }
    #expect(try call(1, values).status == status)
  }

  @Test func aReportedIncomingConversationIsIdle() {
    #expect(waiting.status == "idle", "LiveCommunicationKit has no ringing state")
  }

  @Test func appMergeAcceptsARingingTargetWithoutCapabilities() throws {
    let ringingTarget = try call(
      2, ["uuid": "ringing-target", "ringing": true, "capabilities": []])
    let endedTarget = try call(3, ["uuid": "ended-target", "ended": true])
    let staleTarget = try call(1, ["uuid": "ended-target", "connected": true])
    let targets = InspectorLCKProjection.appMergeTargets(
      for: waiting, calls: [waiting, ringingTarget, staleTarget, endedTarget])
    #expect(targets.map(\.uuid) == ["ringing-target"])
    #expect(InspectorLCKProjection.appMergeTargets(for: waiting, calls: [waiting]).isEmpty)
  }

  @Test func actionsShowTheReportedAndTheEffectiveDeadline() throws {
    let pause = try event(
      1, 0, "action.deadline",
      [
        "apiKind": "livecommunicationkit", "kind": "hold", "deadlineMS": 31_000,
        "deadlineSeconds": 30, "expiryMS": 6_300, "expirySeconds": 5.3,
      ])
    let timing = InspectorLCKProjection.actionTiming(for: pause, nowMS: 2_000)
    let reported = try #require(timing.reported)
    let effective = try #require(timing.effective)
    #expect(reported.remainingSeconds == 29)
    #expect(effective.remainingSeconds == 4.3)
    #expect(abs(reported.progress - 1 / 30.0) < 0.000001)
    #expect(abs(effective.progress - 1 / 5.3) < 0.000001)
    #expect(InspectorLCKProjection.actionTiming(for: pause, nowMS: .infinity).effective == nil)

    let join = try call(
      1, ["deadlineMS": 31_000, "deadlineSeconds": 30, "expiryMS": 65_000, "expirySeconds": 64])
    let joinTiming = InspectorLCKProjection.actionTiming(for: join, nowMS: 32_000)
    #expect(joinTiming.reported?.remainingSeconds == 0)
    #expect(joinTiming.reported?.progress == 1)
    #expect(joinTiming.effective?.remainingSeconds == 33)
  }

  @Test func missingOrInvalidDeadlinesShowNoTiming() throws {
    let missing = try call(3, ["apiKind": "livecommunicationkit"])
    #expect(InspectorLCKProjection.actionTiming(for: missing, nowMS: 2_000).effective == nil)
    let invalid = try call(
      1, ["deadlineMS": 31_000, "deadlineSeconds": 0, "expiryMS": 6_300, "expirySeconds": -1])
    let timing = InspectorLCKProjection.actionTiming(for: invalid, nowMS: 2_000)
    #expect(timing.reported == nil)
    #expect(timing.effective == nil)
  }

  @Test func provenanceNamesTheMeasurement() {
    #expect(InspectorLCKProjection.provenance.contains("Measured #85"))
    #expect(InspectorLCKProjection.provenance.contains("iPhone 13"))
  }
}
