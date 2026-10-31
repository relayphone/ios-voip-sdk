import Foundation
import Testing

@testable import CKSimRuntime

/// Replays the iPhone 13 multi-call captures through the runtime's policy, and checks the profile's
/// numbers against them.
struct MeasuredCaptureTests {
  /// System waiting-call composites, named by their capture.
  @Test(arguments: [
    "ha-delay-pause", "ha-reverse", "ha-fail-pause", "ha-fail-join", "ha-pending-pause",
    "ha-pending-join", "ea-delay-end", "ea-fail-end", "ea-pending-end", "third-end-held-accept",
  ])
  func theBarrierJoinsAsTheDeviceDid(capture name: String) throws {
    let rows = try multiCallCapture(name)
    let accepted = name == "third-end-held-accept" ? "C" : "B"
    let join = try #require(
      rows.first { $0.event == "lckmulti.perform" && $0.kind == "Join" && $0.conv == accepted })
    let constituents = rows.filter {
      $0.event == "lckmulti.perform" && abs($0.monoMS - join.monoMS) <= 3
        && ["Pause", "End", "Join"].contains($0.kind)
    }
    #expect(constituents.count == (accepted == "C" ? 3 : 2), "The composite's actions")
    let actions = Set(constituents.compactMap(\.action))
    let terminals = rows.filter { $0.isTerminal && actions.contains($0.action ?? "") }
      .sorted { $0.monoMS < $1.monoMS }
    try #require(terminals.count == actions.count, "Every action settles or times out once")
    let succeeded = terminals.filter { $0.action == join.action }.allSatisfy(\.succeeded)
    let joined = rows.filter {
      $0.event == "lckmulti.changed" && $0.conv == accepted && $0.state == "joined"
    }
    #expect(joined.isEmpty != succeeded)
    if let first = joined.first {
      #expect(first.monoMS >= terminals[terminals.count - 1].monoMS, "Joined after every action")
    }

    let joinAction = try #require(join.action.flatMap(UUID.init(uuidString:)))
    let joinCall = try #require(join.conversation.flatMap(UUID.init(uuidString:)))
    var barrier = LCKMultiCallPolicy.Barrier(
      actions: try constituents.map { try #require($0.action.flatMap(UUID.init(uuidString:))) },
      joining: [joinAction: joinCall])
    for (index, terminal) in terminals.enumerated() {
      let action = try #require(terminal.action.flatMap(UUID.init(uuidString:)))
      let released = barrier.settle(action, fulfilled: terminal.succeeded)
      if index < terminals.count - 1 {
        #expect(released == nil)
      } else {
        #expect(released == (succeeded ? [joinCall] : []))
      }
    }
  }

  @Test func theHeldCallPausesBeforeAPauseIsFulfilled() throws {
    let rows = try multiCallCapture("ha-delay-pause")
    let join = try #require(rows.first { $0.event == "lckmulti.perform" && $0.kind == "Join" && $0.conv == "B" })
    let pause = try #require(
      rows.first {
        $0.event == "lckmulti.perform" && $0.kind == "Pause" && abs($0.monoMS - join.monoMS) <= 3
      })
    let paused = try #require(
      rows.first { $0.event == "lckmulti.changed" && $0.conv == "A" && $0.state == "paused" })
    let settled = try #require(rows.first { $0.isTerminal && $0.action == pause.action })
    #expect(paused.monoMS < settled.monoMS)
    let profile = try behaviorProfile().lckMultiCall
    #expect(abs(Double(paused.monoMS - pause.monoMS) / 1000 - profile.pausedAfterDeliverySeconds) < 0.05)
  }

  @Test func capabilitiesDontGateThePause() throws {
    let rows = try multiCallCapture("caps-none")
    #expect(rows.first?.capabilities == [])
    #expect(rows.contains { $0.event == "lckmulti.perform" && $0.kind == "Pause" })
  }

  @Test(arguments: ["cap-1x1", "cap-1x2"])
  func anOutgoingCallAtCapacityFailsWithCodeSeven(capture: String) throws {
    let failure = try #require(
      multiCallCapture(capture).first { $0.event == "lckmulti.requestResult" && $0.kind == "Start" })
    #expect(failure.code == 7 && failure.domain == "com.apple.CallKit.error.requesttransaction")
  }

  @Test(arguments: ["merge-b-into-a", "merge-a-into-b"])
  func mergingChangesNoConversationState(capture: String) throws {
    let snapshots = try multiCallCapture(capture).filter { $0.event == "lckmulti.snapshot" }
    func states(_ row: CaptureRow?) throws -> [String: String] {
      Dictionary(
        uniqueKeysWithValues: try #require(row?.conversations).map { ($0.uuid, $0.state) })
    }
    let before = try states(snapshots.first { $0.label == "B-after-choice" })
    let after = try states(snapshots.first { $0.label?.hasPrefix("after-merge-") == true })
    #expect(before == after)
  }

  @Test(arguments: [("ha-pending-pause", "Pause"), ("ha-pending-join", "Join"), ("ea-pending-end", "End")])
  func pendingActionsExpireLongBeforeTheirAdvertisedTimeout(capture: String, kind: String) throws {
    let rows = try multiCallCapture(capture)
    let timeout = try #require(rows.first { $0.event == "lckmulti.timedOut" && $0.kind == kind })
    let delivered = try #require(
      rows.first { $0.event == "lckmulti.perform" && $0.action == timeout.action })
    #expect((29_900...30_100).contains(delivered.timeoutIn ?? 0), "LCK advertises 30 seconds")
    let profile = try behaviorProfile().lckMultiCall
    let expected = kind == "Join" ? profile.joinExpirySeconds : profile.pauseEndExpirySeconds
    #expect(abs(Double(timeout.monoMS - delivered.monoMS) / 1000 - expected) < 0.15)
  }

  @Test func aCleanupEndTimesOutEvenWhenFulfilled() throws {
    let rows = try multiCallCapture("ha-fail-pause")
    let cleanup = try #require(
      rows.first { $0.event == "lckmulti.perform" && $0.kind == "End" && $0.conv == "A" })
    let settled = try #require(
      rows.first { $0.event == "lckmulti.settled" && $0.action == cleanup.action })
    let timeout = try #require(
      rows.first { $0.event == "lckmulti.timedOut" && $0.action == cleanup.action })
    #expect(settled.failed == false && timeout.monoMS > settled.monoMS)
    let profile = try behaviorProfile().lckMultiCall
    #expect(
      abs(Double(timeout.monoMS - cleanup.monoMS) / 1000 - profile.cleanupEndExpirySeconds) < 0.2)
  }

  @Test func resumingTheHeldCallEndsTheActiveOne() throws {
    let rows = try multiCallCapture("swap-app")
    let resumed = try #require(
      rows.first { $0.event == "lckmulti.perform" && $0.kind == "Pause" && $0.isPaused == false })
    let ended = try #require(
      rows.first { $0.event == "lckmulti.perform" && $0.kind == "End" && $0.conv == "B" })
    #expect(ended.action != resumed.action)
    let profile = try behaviorProfile().lckMultiCall
    #expect(Double(ended.monoMS - resumed.monoMS) / 1000 == profile.appResumeEndDelaySeconds)
  }
}
