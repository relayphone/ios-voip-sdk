#if os(iOS) && targetEnvironment(simulator)
  import CKSimProtocol
  import Foundation
  import Testing

  extension RuntimeSuites {
    /// When the runtime activates and deactivates audio for a LiveCommunicationKit app. The
    /// runtime schedules audio in real time, so these check order and lower bounds: a timer never
    /// fires early.
    @Suite @MainActor struct LCKAudio {
      /// Audio activates `delay` milliseconds after the action settles, not when it's delivered.
      private func expectAudio(
        _ session: LCKSession, after settled: Entry, by delay: Int,
        sourceLocation: SourceLocation = #_sourceLocation
      ) async throws {
        let activated = try await session.callback("didActivate", sourceLocation: sourceLocation)
        #expect(activated.sequence > settled.sequence, sourceLocation: sourceLocation)
        #expect(activated.time - settled.time >= delay - 2, sourceLocation: sourceLocation)
      }

      @Test func aJoinActivatesAudioAfterItSettles() async throws {
        let session = try await LCKSession()
        try await session.app.reportIncoming("A")
        let actions = try await session.system { .answer($0.id("A")) }
        #expect(actions.count == 1)
        let settled = try await session.callback("settled") {
          $0.kind == "Join" && $0.actionID == actions.first?.uuidString
        }
        try await session.expect(["A": "joined"])
        try await expectAudio(session, after: settled, by: 290)
        try await session.finish()
      }

      @Test func aStartActivatesAudioAfterItSettles() async throws {
        let session = try await LCKSession()
        try await session.app.start("A")
        let started = try await session.callback("perform") {
          $0.kind == "Start" && $0.callUUID == session.app.id("A").uuidString
        }
        let settled = try await session.callback("settled") { $0.actionID == started.actionID }
        try await expectAudio(session, after: settled, by: 230)
        try await session.finish()
      }

      @Test func aMuteDuringAPendingJoinActivatesAudioOnce() async throws {
        let session = try await LCKSession()
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
        #expect(activated.time - joined.time >= 288, "Audio waits for the Join")
        try await Task.sleep(for: .milliseconds(350))
        let rows = try session.entries()
        #expect(rows.count { $0.event == "lck.fixture.didActivate" } == 1)
        #expect(!rows.contains { $0.event == "lck.fixture.didDeactivate" })
        try await session.finish()
      }

      @Test(arguments: [("hold-and-accept", "Pause", "paused"), ("end-and-accept", "End", "left")])
      func aCompositeMovesAudioAfterItsLastActionSettles(
        control: String, delayed: String, a: String
      ) async throws {
        let session = try await LCKSession()
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
        let late = try #require(settled.first { $0.kind == delayed })
        let lateDelivery = try #require(performed.first { $0.actionID == late.actionID })
        #expect(late.time - lateDelivery.time >= 1998)
        let join = try #require(settled.first { $0.kind == "Join" })
        #expect(join.sequence < late.sequence, "The Join settles while the other action is pending")
        let last = try #require(settled.map(\.sequence).max())
        let joined = try #require(
          rows.first {
            $0.event == "lck.fixture.changed" && $0.callUUID == session.app.id("B").uuidString
              && $0.state == "joined"
          })
        #expect(joined.sequence > last && activated.sequence > last)
        #expect(
          rows.contains {
            $0.event == "lck.fixture.didDeactivate" && $0.sequence < activated.sequence
          },
          "Audio deactivates before it activates for B")
        #expect(activated.time - late.time >= 113)
        try await session.finish()
      }

      @Test func aLateResumeEndsTheActiveCallOnceItSettles() async throws {
        let session = try await LCKSession()
        try await session.pair()
        let handoff = try session.runtime.cursor()
        _ = try await session.composite()
        try await session.expect(["A": "paused", "B": "joined"])
        try await session.callback("didActivate", after: handoff)
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
        try await session.finish()
      }
    }
  }
#endif
