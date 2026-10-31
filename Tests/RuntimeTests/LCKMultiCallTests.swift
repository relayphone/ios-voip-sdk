#if os(iOS) && targetEnvironment(simulator)
  import CKSimProtocol
  import Foundation
  import Testing

  extension RuntimeSuites {
    /// Call waiting through a genuine LiveCommunicationKit conversation manager, following the
    /// iPhone 13 measurements. The choices and the shared transaction are the runtime's policy:
    /// LiveCommunicationKit exposes neither.
    @Suite @MainActor struct LCKMultiCall {
      @Test func aLatePauseHoldsBackTheJoin() async throws {
        try await exclusively {
          let session = try await LCKSession()
          try await session.pair()
          #expect(
            try await session.choices("B") == ["hold-and-accept", "end-and-accept", "decline"])
          session.app.settle("Pause", .delay(milliseconds: 2000))
          let actions = try await session.composite()
          try await session.expect(["A": "paused", "B": "joined"])
          try session.expectJoinedAfterEveryAction(actions)
          let rows = try session.entries()
          let settled = try #require(
            rows.first { $0.event == "lck.fixture.settled" && $0.kind == "Pause" })
          let delivered = try #require(
            rows.first { $0.event == "lck.fixture.perform" && $0.actionID == settled.actionID })
          #expect(settled.time - delivered.time >= 1900)
          let paused = try #require(
            rows.first {
              $0.event == "lck.fixture.changed" && $0.callUUID == session.app.id("A").uuidString
                && $0.state == "paused"
            })
          #expect(paused.time < settled.time, "A pauses before its Pause is fulfilled")
          try await session.finish()
        }
      }

      @Test func actionsSettledInReverseStillJoinOnce() async throws {
        try await exclusively {
          let session = try await LCKSession()
          try await session.pair()
          session.app.settle("Pause", .reverse(milliseconds: 630))
          session.app.settle("Join", .reverse(milliseconds: 630))
          let actions = try await session.composite()
          try await session.expect(["A": "paused", "B": "joined"])
          try session.expectJoinedAfterEveryAction(actions)
          let settled = try session.entries().filter {
            $0.event == "lck.fixture.settled" && actions.contains($0.actionID ?? "")
          }
          #expect(settled.map(\.kind) == ["Join", "Pause"])
          try await session.finish()
        }
      }

      @Test(arguments: [
        ("hold-and-accept", "Pause", "left", "joined"),
        ("hold-and-accept", "Join", "paused", "left"),
        ("end-and-accept", "End", "left", "joined"),
        ("end-and-accept", "Join", "left", "left"),
      ])
      func aFailedActionEndsItsConversation(
        control: String, failing: String, a: String, b: String
      ) async throws {
        try await exclusively {
          let session = try await LCKSession()
          try await session.pair()
          session.app.settle(failing, .fail, nth: 1)
          let actions = try await session.composite(control)
          try await session.expect(["A": a, "B": b])
          if failing != "End" {
            let target = session.app.id(failing == "Pause" ? "A" : "B").uuidString
            try await session.callback("perform") {
              $0.kind == "End" && $0.callUUID == target && !actions.contains($0.actionID ?? "")
            }
          }
          if b == "joined" { try session.expectJoinedAfterEveryAction(actions) }
          if a == "paused" {
            try await Task.sleep(for: .milliseconds(300))
            #expect(
              session.app.state("A") == "paused", "A failed Join doesn't resume the held call")
          }
          try await session.finish()
        }
      }

      @Test(arguments: [
        ("hold-and-accept", "Pause", "left", "joined"),
        ("end-and-accept", "End", "left", "joined"),
        ("hold-and-accept", "Join", "paused", "left"),
      ])
      func aPendingActionExpiresAfterTheMeasuredTimeNotTheAdvertisedOne(
        control: String, pending: String, a: String, b: String
      ) async throws {
        try await exclusively {
          let session = try await LCKSession()
          try await session.pair()
          session.app.settle(pending, .pending, nth: 1)
          let actions = try await session.composite(control)
          let delivered = try await session.callback("perform") {
            actions.contains($0.actionID ?? "") && $0.kind == pending
          }
          let expired = try await session.callback(
            "timedOut", limit: .seconds(pending == "Join" ? 75 : 15)
          ) { $0.actionID == delivered.actionID }
          let issued = try await session.runtime.entry("the action's issue", after: session.cursor)
          {
            $0.event == "action.deadline" && $0.actionID == delivered.actionID
          }
          let issuedAt = Double(try #require(issued.issuedAtMS))
          let advertised = try #require(delivered.advertisedDeadlineMS) - issuedAt
          #expect((29_000...31_000).contains(advertised), "LiveCommunicationKit advertises 30 s")
          #expect(Double(expired.wallTimeMS) - issuedAt >= (pending == "Join" ? 63_000 : 5_000))
          try await session.expect(["A": a, "B": b])
          if pending != "End" {
            let target = session.app.id(pending == "Pause" ? "A" : "B").uuidString
            try await session.callback("perform") {
              $0.kind == "End" && $0.callUUID == target && !actions.contains($0.actionID ?? "")
            }
          }
          if b == "joined" { try session.expectJoinedAfterEveryAction(actions) }
          try await session.finish()
        }
      }

      @Test func capabilitiesDontLimitTheChoicesOrThePause() async throws {
        try await exclusively {
          let session = try await LCKSession(capabilities: [])
          try await session.pair()
          #expect(try await session.choices("B").contains("hold-and-accept"))
          _ = try await session.composite()
          try await session.expect(["A": "paused", "B": "joined"])
          try await session.app.pause("B", true)
          try await session.expect(["A": "paused", "B": "paused"])
          try await session.finish()
        }
      }

      @Test func removingCapabilitiesDuringACallChangesNothing() async throws {
        try await exclusively {
          let session = try await LCKSession()
          try await session.pair()
          try session.app.update("A", capabilities: [])
          #expect(try await session.choices("B").contains("hold-and-accept"))
          _ = try await session.composite()
          try await session.expect(["A": "paused", "B": "joined"])
          try session.app.update("B", capabilities: [])
          try await session.app.pause("B", true)
          try await session.expect(["A": "paused", "B": "paused"])
          try await session.finish()
        }
      }

      /// Merges or unmerges from the app, then checks that no conversation changed state.
      private func expectUnchanged(
        _ session: LCKSession, _ kind: String, _ states: [String: String],
        _ action: () async throws -> Void
      ) async throws {
        let start = try session.runtime.cursor()
        try await action()
        try await session.callback("settled", after: start) { $0.kind == kind }
        try await Task.sleep(for: .milliseconds(200))
        session.app.snapshot("after-\(kind)")
        let expected = Dictionary(
          uniqueKeysWithValues: states.map { (session.app.id($0.key).uuidString, $0.value) })
        let rows = try session.entries(after: start)
        for row in rows where row.event == "lck.fixture.changed" {
          if let state = expected[row.callUUID ?? ""] { #expect(row.state == state) }
        }
        let snapshot = try #require(rows.last { $0.event == "lck.fixture.snapshot" })
        let actual = Dictionary(
          uniqueKeysWithValues: (snapshot.conversations ?? []).map { ($0.callUUID, $0.state) })
        for (call, state) in expected { #expect(actual[call] == state) }
      }

      @Test func mergingAndUnmergingChangeNoStateAndAFullGroupLimitsTheChoices() async throws {
        try await exclusively {
          let session = try await LCKSession(perGroup: 2)
          try await session.pair()
          _ = try await session.composite()
          try await session.expect(["A": "paused", "B": "joined"])
          let states = ["A": "paused", "B": "joined"]
          try await expectUnchanged(session, "Merge", states) {
            try await session.app.merge("B", with: "A")
          }
          try await expectUnchanged(session, "Merge", states) {
            try await session.app.merge("A", with: "B")
          }
          try await expectUnchanged(session, "Unmerge", states) {
            try await session.app.unmerge("A")
          }
          try await expectUnchanged(session, "Unmerge", states) {
            try await session.app.unmerge("B")
          }
          try await session.app.reportIncoming("C")
          #expect(
            try await session.choices("C") == ["end-and-accept", "end-held-and-accept", "decline"])
          let error = try #require(await capture { try await session.app.start("D") })
          #expect(error.domain == "com.apple.CallKit.error.requesttransaction" && error.code == 7)
          _ = try await session.composite("end-held-and-accept", call: "C", active: "B", held: "A")
          try await session.expect(["A": "left", "B": "paused", "C": "joined"])
          try await session.finish()
        }
      }

      @Test func endAndAcceptWithACallOnHold() async throws {
        try await exclusively {
          let session = try await LCKSession()
          try await session.pair()
          _ = try await session.composite()
          try await session.expect(["A": "paused", "B": "joined"])
          try await session.app.reportIncoming("C")
          _ = try await session.composite("end-and-accept", call: "C", active: "B")
          try await session.expect(["A": "paused", "B": "left", "C": "joined"])
          try await session.finish()
        }
      }

      @Test func unmergingASingleConversationChangesNothing() async throws {
        try await exclusively {
          let session = try await LCKSession(perGroup: 2)
          try await session.app.reportIncoming("A")
          try await session.system { .answer($0.id("A")) }
          try await session.expect(["A": "joined"])
          try await expectUnchanged(session, "Unmerge", ["A": "joined"]) {
            try await session.app.unmerge("A")
          }
          try await session.finish()
        }
      }

      @Test func resumingTheHeldCallEndsTheActiveOne() async throws {
        try await exclusively {
          let session = try await LCKSession()
          try await session.pair()
          _ = try await session.composite()
          try await session.expect(["A": "paused", "B": "joined"])
          let start = try session.runtime.cursor()
          try await session.app.pause("A", false)
          try await session.expect(["A": "joined", "B": "left"])
          let b = session.app.id("B").uuidString
          let actions = try session.entries(after: start).filter {
            $0.event == "lck.fixture.perform" && $0.callUUID == b
          }
          #expect(actions.map(\.kind) == ["End"], "B ends rather than pausing")
          try await session.finish()
        }
      }

      @Test(arguments: [1, 2])
      func withOneGroupTheSystemCanOnlyEndAndAccept(perGroup: Int) async throws {
        try await exclusively {
          let session = try await LCKSession(groups: 1, perGroup: perGroup)
          try await session.pair()
          #expect(try await session.choices("B") == ["end-and-accept", "decline"])
          let error = try #require(await capture { try await session.app.start("C") })
          #expect(error.domain == "com.apple.CallKit.error.requesttransaction" && error.code == 7)
          try await session.finish()
        }
      }

      @Test func anInjectedErrorFailsTheReportUntilItIsCleared() async throws {
        try await exclusively {
          let session = try await LCKSession()
          let handle = "+15555550199"
          try await session.app.reportIncoming("normal", handle: handle)
          try await session.system { .answer($0.id("normal")) }
          try await session.expect(["normal": "joined"])
          try await session.system { .end($0.id("normal")) }
          try await session.expect(["normal": "left"])
          try await session.runtime.control(.faults([.incomingErrorCode(4)]))
          let error = try #require(
            await capture { try await session.app.reportIncoming("filtered", handle: handle) })
          #expect(error.domain == "com.apple.CallKit.error.incomingcall" && error.code == 4)
          try await session.runtime.control(.faults([.incomingErrorCode(0)]))
          try await session.app.reportIncoming("cleared", handle: handle)
          try await session.system { .answer($0.id("cleared")) }
          try await session.expect(["cleared": "joined"])
          try await session.finish()
        }
      }
    }
  }

  /// The error that `body` throws, as Foundation reports it.
  @MainActor
  func capture(_ body: () async throws -> Void) async -> NSError? {
    do {
      try await body()
      return nil
    } catch {
      return error as NSError
    }
  }
#endif
