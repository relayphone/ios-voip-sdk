#if os(iOS) && targetEnvironment(simulator)
  import CKSimProtocol
  import Foundation
  import Testing

  extension RuntimeSuites {
    /// A CallKit app's calls through the runtime, driven from the system's side as `cksim` drives
    /// them, and the journal that records them.
    @Suite @MainActor struct CallKitJourney {
      private let runtime: Runtime
      private let app: CallKitApp

      init() throws {
        runtime = try Runtime.shared()
        app = CallKitApp()
      }

      /// The call the runtime has that isn't in `known`, once it appears.
      private func newCall(besides known: Set<UUID>) async throws -> UUID {
        try await runtime.until("a new call") {
          try await runtime.status().calls.map(\.state.uuid).first { !known.contains($0) }
        }
      }

      /// Waits until the call's state matches.
      private func expect(
        _ call: UUID, _ description: String, _ matches: @escaping (CallSnapshot.State) -> Bool
      ) async throws {
        try await runtime.until("the call to be \(description)") {
          let state = try await runtime.status().calls.first { $0.state.uuid == call }?.state
          return state.map(matches) == true ? true : nil
        }
      }

      @Test func callsMoveThroughTheSystemControlsAndTheJournalRecordsThem() async throws {
        defer { app.stop() }
        try await runtime.clearSettings()
        let cursor = try runtime.cursor()
        var known = Set(try await runtime.status().calls.map(\.state.uuid))

        try await runtime.push(["operation": .string("incoming")], mustReport: false)
        var active = try await newCall(besides: known)
        known.insert(active)
        try await runtime.perform(.answer(active))
        try await expect(active, "connected") { $0.connected }
        try await runtime.entry("audio to activate", after: cursor) {
          $0.event == "audio.activated"
        }
        try await runtime.perform(.mute(active, muted: true))
        try await expect(active, "muted") { $0.muted }
        try await runtime.perform(.tones(active, digits: "12#"))
        try await runtime.entry("the app to fail the tones", after: cursor) {
          $0.event == "action.settled" && $0.kind == "tones" && $0.fulfilled == false
        }

        // Call waiting: decline a second call, then hold and accept one, then end and accept
        // another.
        try await runtime.push(["operation": .string("incoming")], mustReport: false)
        let declined = try await newCall(besides: known)
        known.insert(declined)
        try await runtime.perform(.decline(declined))
        try await runtime.until("the declined call to end") {
          try await runtime.status().calls.contains { $0.state.uuid == declined } ? nil : true
        }
        for control in ["hold-and-accept", "end-and-accept"] {
          try await runtime.push(["operation": .string("incoming")], mustReport: false)
          let waiting = try await newCall(besides: known)
          known.insert(waiting)
          if control == "hold-and-accept" {
            try await runtime.perform(.holdAndAccept(waiting, active: active))
            try await expect(active, "held") { $0.held }
          } else {
            try await runtime.perform(.endAndAccept(waiting, active: active))
          }
          try await expect(waiting, "connected") { $0.connected }
          active = waiting
        }
        try await runtime.end(known)

        try await runtime.push(["operation": .string("outgoing")], mustReport: false)
        try await runtime.entry("the outgoing call to connect", after: cursor) {
          $0.event == "report.connected"
        }
        let calls = try await runtime.status().calls.map(\.state.uuid)
        try await runtime.end(calls)

        let entries = try runtime.entries()
        #expect(entries.map(\.sequence) == Array(1...entries.count), "Sequences are contiguous")
        for entry in entries {
          #expect(entry.schemaVersion == 1)
          #expect(
            entry.runID == runtime.session.runID && entry.pid == runtime.session.pid
              && entry.bundleID == runtime.session.bundleID)
        }
        let journey = Array(entries.dropFirst(cursor))
        let events = Set(journey.map(\.event))
        let expected: Set = [
          "report.incoming", "report.completed", "report.updated", "report.connecting",
          "report.connected", "action.deadline", "action.settled", "call.changed",
          "audio.activated", "push.received", "push.completed",
        ]
        #expect(expected.isSubset(of: events), "Missing \(expected.subtracting(events))")
        for entry in journey where entry.event.hasPrefix("action.") {
          #expect(entry.kind != nil && entry.origin != nil && entry.callUUID != nil)
          #expect(entry.transactionID != nil && entry.apiKind == "callkit")
          #expect(entry.deadlineMS != nil && entry.deadlineSeconds != nil)
          let latency = try #require(entry.latencyMS)
          #expect(latency.isFinite && latency >= 0)
          if entry.event == "action.settled" {
            #expect(latency >= 50, "The app settles 120 ms after delivery")
          }
        }
      }
    }
  }
#endif
