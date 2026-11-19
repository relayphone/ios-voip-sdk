#if os(iOS) && targetEnvironment(simulator)
  import CKSimProtocol
  import Foundation
  import Testing

  extension RuntimeSuites {
    /// When the simulator runtime activates and deactivates audio for a LiveCommunicationKit app.
    @Suite @MainActor struct LCKAudio {
      private func checkActivation(
        _ activated: Entry, after settled: Entry, in rows: [Entry], scenario: String,
        delayMS: Double? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
      ) throws {
        #expect(activated.sequence > settled.sequence, sourceLocation: sourceLocation)
        let actionID = try #require(settled.actionID, sourceLocation: sourceLocation)
        let settlement = rows.first { $0.event == "action.settled" && $0.actionID == actionID }
        let activation = rows.first { $0.event == "audio.activated" }
        let runtimeSettled = try #require(settlement, sourceLocation: sourceLocation)
        let runtimeActivated = try #require(activation, sourceLocation: sourceLocation)
        #expect(runtimeActivated.sequence > runtimeSettled.sequence, sourceLocation: sourceLocation)
        #expect(activated.sequence > runtimeActivated.sequence, sourceLocation: sourceLocation)

        // The runtime starts its timer inside fulfill(), before the fixture logs settlement.
        let runtimeMS =
          Double(
            Int64(runtimeActivated.uptimeNanoseconds) - Int64(runtimeSettled.uptimeNanoseconds))
          / 1_000_000
        let callbackMS = activated.time - settled.time
        NSLog("LCK_AUDIO_TIMING \(scenario) \(runtimeMS) \(callbackMS)")
        if let delayMS {
          // Allow one millisecond for the runtime's dispatch timer leeway.
          #expect(runtimeMS >= delayMS - 1, sourceLocation: sourceLocation)
        }
      }

      @Test func aJoinActivatesAudioAfterItSettles() async throws {
        try await withLCKSession { session in
          try await session.app.reportIncoming("A")
          let actions = try await session.system { .answer($0.id("A")) }
          #expect(actions.count == 1)
          let settled = try await session.callback("settled") {
            $0.kind == "Join" && $0.actionID == actions.first?.uuidString
          }
          try await session.expect(["A": "joined"])
          let activated = try await session.callback("didActivate")
          try checkActivation(
            activated, after: settled, in: session.entries(), scenario: "join", delayMS: 290)
        }
      }

      @Test func aStartActivatesAudioAfterItSettles() async throws {
        try await withLCKSession { session in
          try await session.app.start("A")
          let started = try await session.callback("perform") {
            $0.kind == "Start" && $0.callUUID == session.app.id("A").uuidString
          }
          let settled = try await session.callback("settled") { $0.actionID == started.actionID }
          let activated = try await session.callback("didActivate")
          try checkActivation(
            activated, after: settled, in: session.entries(), scenario: "start", delayMS: 230)
        }
      }

      @Test func aMuteDuringAPendingJoinActivatesAudioOnce() async throws {
        try await withLCKSession { session in
          try await session.app.reportIncoming("A")
          let answer = try await session.system { .answer($0.id("A")) }
          let joined = try await session.callback("settled") {
            $0.kind == "Join" && $0.actionID == answer.first?.uuidString
          }
          try await Task.sleep(for: .milliseconds(100))
          let mute = Set(
            try await session.system { .mute($0.id("A"), muted: true) }.map(\.uuidString))
          try await session.callback("settled") { mute.contains($0.actionID ?? "") }
          let activated = try await session.callback("didActivate")
          try checkActivation(
            activated, after: joined, in: session.entries(), scenario: "mute-during-join",
            delayMS: 290)
          try await Task.sleep(for: .milliseconds(350))
          let rows = try session.entries()
          let activations = rows.count { $0.event == "lck.fixture.didActivate" }
          let deactivated = rows.contains { $0.event == "lck.fixture.didDeactivate" }
          #expect(activations == 1)
          #expect(!deactivated)
        }
      }

      @Test(arguments: [("hold-and-accept", "Pause", "paused"), ("end-and-accept", "End", "left")])
      func aCompositeMovesAudioAfterItsLastActionSettles(
        control: String, delayed: String, a: String
      ) async throws {
        try await withLCKSession { session in
          try await session.pair()
          session.app.settle(delayed, .delay(milliseconds: 2000), nth: 1)
          let start = try session.runtime.cursor()
          let actions = try await session.composite(control)
          try await session.expect(["A": a, "B": "joined"])
          let activated = try await session.callback("didActivate", after: start)
          let rows = try session.entries(after: start)
          let performed = rows.filter {
            $0.event == "lck.fixture.perform" && actions.contains($0.actionID ?? "")
          }
          let settled = rows.filter {
            $0.event == "lck.fixture.settled" && actions.contains($0.actionID ?? "")
          }
          let lateSettlement = settled.first { $0.kind == delayed }
          let late = try #require(lateSettlement)
          let lateDeliveries = performed.filter { $0.actionID == late.actionID }
          let lateDelivery = try #require(lateDeliveries.first)
          #expect(late.time - lateDelivery.time >= 1998)
          let join = try #require(settled.first { $0.kind == "Join" })
          #expect(
            join.sequence < late.sequence, "The Join settles while the other action is pending")
          let lastSettlement = settled.max { $0.sequence < $1.sequence }
          let last = try #require(lastSettlement)
          let joined = try #require(
            rows.first {
              $0.event == "lck.fixture.changed" && $0.callUUID == session.app.id("B").uuidString
                && $0.state == "joined"
            })
          #expect(joined.sequence > last.sequence)
          #expect(
            rows.contains {
              $0.event == "lck.fixture.didDeactivate" && $0.sequence < activated.sequence
            },
            "Audio deactivates before it activates for B")
          try checkActivation(activated, after: last, in: rows, scenario: control, delayMS: 115)
        }
      }

      @Test func aLateResumeEndsTheActiveCallOnceItSettles() async throws {
        try await withLCKSession { session in
          try await session.pair()
          let handoff = try session.runtime.cursor()
          let handoffActions = try await session.composite()
          try await session.expect(["A": "paused", "B": "joined"])
          let activated = try await session.callback("didActivate", after: handoff)
          let handoffRows = try session.entries(after: handoff)
          let handoffSettlement = handoffRows.last {
            $0.event == "lck.fixture.settled" && handoffActions.contains($0.actionID ?? "")
          }
          let handoffSettled = try #require(handoffSettlement)
          try checkActivation(
            activated, after: handoffSettled, in: handoffRows, scenario: "late-resume-handoff")
          session.app.settle("Pause", .delay(milliseconds: 300), nth: 1)
          let start = try session.runtime.cursor()
          try await session.app.pause("A", false)
          let a = session.app.id("A").uuidString
          let b = session.app.id("B").uuidString
          let resumed = try await session.callback("perform", after: start) {
            $0.kind == "Pause" && $0.callUUID == a && $0.held == false
          }
          let settled = try await session.callback("settled", after: start) {
            $0.actionID == resumed.actionID
          }
          #expect(settled.policy == "delay" && settled.failed == false)
          #expect(settled.time - resumed.time >= 298)
          let ended = try await session.callback("perform", after: start) {
            $0.kind == "End" && $0.callUUID == b
          }
          #expect(ended.sequence > settled.sequence, "B ends only after A's resume settles")
          let actions = try session.entries(after: start).filter {
            $0.event == "lck.fixture.perform" && $0.callUUID == b
          }
          #expect(actions.map(\.kind) == ["End"])
          try await session.expect(["A": "joined", "B": "left"])
        }
      }
    }
  }
#endif
