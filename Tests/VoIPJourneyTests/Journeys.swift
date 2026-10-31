#if os(iOS) && targetEnvironment(simulator)
  import CKSimProtocol
  import Foundation
  import Testing
  import VoIPCore
  import VoIPTesting

  /// Call journeys through the LiveCommunicationKit adapter and the PushKit source, with the
  /// simulator runtime acting as the system. They run one at a time, because a process has one
  /// calling framework provider.
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct Journeys {
    @Test func pushAnswerConnectAndEndRemotely() async throws {
      let id = newCallID("answer")
      var pushID = UUID()
      // The push waits for the app's PushKit registry, as when a VoIP push launches the app.
      let app = try await App {
        pushID = try await $0.pushIncomingCall(
          id,
          metadata: [
            "room": .string("room-1"),
            "route": .object(["attempt": .integer(2), "hops": .array([.string("sip"), .null])]),
          ])
      }
      defer { app.stop() }
      try await app.expect([.presented(id)])
      try await app.until("the call to appear") { app.call(id) != nil }
      #expect(
        app.call(id)?.metadata == [
          "room": "room-1", "route": ["attempt": 2, "hops": ["sip", .null]],
        ])
      let uuid = deviceUUID(for: id)
      #expect(try await app.system.calls().map(\.uuid) == [uuid])

      try await app.system.perform(.answer(uuid))
      try await app.expect([.performed(.answer(id), .connecting), .audioActivated])
      #expect(await app.media.records.map(\.kind) == [.prepare, .activate])

      await app.client.receive(.connected, for: id, eventID: EventID(rawValue: "connected-\(id)"))
      try await app.until("the call to connect") { app.call(id)?.status == .connected }

      await app.client.receive(.endedRemotely, for: id, eventID: EventID(rawValue: "end-\(id)"))
      try await app.expect([.ended(id, .endedRemotely), .audioDeactivated])
      try await app.until("the system to end the call") { try await app.system.calls().isEmpty }
      #expect(await app.media.records.map(\.kind) == [.prepare, .activate, .deactivate])
      try await app.expectPushesFinished([pushID])
      app.expectNoMoreEvents()
    }

    @Test func declineFromTheCallScreen() async throws {
      let app = try await App()
      defer { app.stop() }
      let id = newCallID("decline")
      let pushID = try await app.system.pushIncomingCall(id)
      try await app.expect([.presented(id)])

      try await app.system.perform(.decline(deviceUUID(for: id)))
      try await app.expect([.performed(.end(id), .ended(.endedHere)), .ended(id, .endedHere)])
      try await app.until("the system to end the call") { try await app.system.calls().isEmpty }
      #expect(await app.media.records.isEmpty)
      try await app.expectPushesFinished([pushID])
      app.expectNoMoreEvents()
    }

    @Test func answeredElsewhereBecomesAPreview() async throws {
      let app = try await App()
      defer { app.stop() }
      let id = newCallID("elsewhere")
      let invite = try await app.system.pushIncomingCall(id)
      try await app.expect([.presented(id)])

      // The server tells this device with another VoIP push, which the SDK reports again
      // under the call's own UUID.
      let ended = try await app.system.pushCallEnded(id, reason: "answeredElsewhere")
      try await app.expect([.previewStarted(id, .answeredElsewhere)])
      try await app.until("the system to end the call") { try await app.system.calls().isEmpty }
      #expect(app.call(id)?.status == .previewing(.answeredElsewhere))
      #expect(await app.media.records.isEmpty)
      try await app.expectPushesFinished([invite, ended])
      app.expectNoMoreEvents()
    }

    @Test func unrecognizedPushIsReportedAndEndedAtOnce() async throws {
      let app = try await App()
      defer { app.stop() }
      // PushKit requires every VoIP push to be reported as a call, even one the app can't read.
      let pushID = try await app.system.push(["aps": .object([:]), "greeting": .string("hello")])
      try await app.expectPushesFinished([pushID])
      try await app.until("the system to end the reported call") {
        try await app.system.calls().isEmpty
      }
      #expect(app.client.calls.isEmpty)
      app.expectNoMoreEvents()
    }

    @Test func filteredCallBecomesAPreview() async throws {
      let app = try await App()
      defer { app.stop() }
      try await app.system.filterIncomingCalls(.doNotDisturb)
      let id = newCallID("filtered")
      let pushID: UUID
      do {
        pushID = try await app.system.pushIncomingCall(id)
        // The system takes about 2 seconds to refuse a filtered report.
        try await app.expect([.previewStarted(id, .filtered(.doNotDisturb))])
      } catch {
        try await app.system.filterIncomingCalls(.none)
        throw error
      }
      try await app.system.filterIncomingCalls(.none)
      #expect(try await app.system.calls().isEmpty)
      #expect(app.call(id)?.status == .previewing(.filtered(.doNotDisturb)))
      #expect(await app.media.records.isEmpty)
      try await app.expectPushesFinished([pushID])
      app.expectNoMoreEvents()
    }

    @Test func outgoingCallConnectsAndEndsHere() async throws {
      let app = try await App()
      defer { app.stop() }
      let id = newCallID("outgoing")
      let bob = try Party(handle: Handle(kind: .phoneNumber, value: "+442071838750"))
      try await app.client.request(.start(OutgoingCall(id: id, parties: [bob])))
      try await app.expect([.startRequested(id)])
      #expect(try await app.system.calls().map(\.outgoing) == [true])

      await app.client.confirmPlaced(id)
      try await app.expect([
        .performed(.start(OutgoingCall(id: id, parties: [bob])), .dialing), .audioActivated,
      ])
      await app.client.receive(.connected, for: id, eventID: EventID(rawValue: "connected-\(id)"))
      try await app.until("the call to connect") { app.call(id)?.status == .connected }
      try await app.until("the system to see the call connected") {
        try await app.system.calls().map(\.connected) == [true]
      }

      try await app.client.request(.end(id))
      try await app.expect([
        .performed(.end(id), .ended(.endedHere)), .ended(id, .endedHere), .audioDeactivated,
      ])
      try await app.until("the system to end the call") { try await app.system.calls().isEmpty }
      app.expectNoMoreEvents()
    }

    @Test func muteHoldAndTonesFromTheCallScreen() async throws {
      let id = newCallID("controls")
      let app = try await App()
      defer { app.stop() }
      try await app.system.pushIncomingCall(id)
      try await app.expect([.presented(id)])
      let uuid = deviceUUID(for: id)
      try await app.system.perform(.answer(uuid))
      try await app.expect([.performed(.answer(id), .connecting), .audioActivated])
      await app.client.receive(.connected, for: id, eventID: EventID(rawValue: "connected-\(id)"))
      try await app.until("the call to connect") { app.call(id)?.status == .connected }

      try await app.system.perform(.mute(uuid, muted: true))
      try await app.expect([.performed(.mute(id, muted: true), .connected)])
      #expect(app.call(id)?.isMuted == true)
      // With its only call on hold, the system deactivates audio, and activates it again when
      // the call resumes.
      try await app.system.perform(.hold(uuid, held: true, origin: .system))
      try await app.expect([.performed(.hold(id, onHold: true), .connected), .audioDeactivated])
      #expect(app.call(id)?.isOnHold == true)
      try await app.system.perform(.hold(uuid, held: false, origin: .system))
      try await app.expect([.performed(.hold(id, onHold: false), .connected), .audioActivated])
      #expect(
        await app.media.records.map(\.kind) == [.prepare, .activate, .deactivate, .activate])
      try await app.system.perform(.tones(uuid, digits: "12#"))
      try await app.expect([.performed(.playTones(id, digits: "12#"), .connected)])
      try await app.system.perform(.mute(uuid, muted: false))
      try await app.expect([.performed(.mute(id, muted: false), .connected)])
      try await app.until("the system to see the call unmuted and resumed") {
        try await app.system.calls().map { [$0.muted, $0.held] } == [[false, false]]
      }

      // The system repeats a mute the app requested once it is fulfilled. The app hears of it
      // once.
      try await app.client.request(.mute(id, muted: true))
      try await app.expect([.performed(.mute(id, muted: true), .connected)])
      try await app.until("the system to see the call muted") {
        try await app.system.calls().map(\.muted) == [true]
      }

      try await app.system.perform(.end(uuid))
      try await app.expect([
        .performed(.end(id), .ended(.endedHere)), .ended(id, .endedHere), .audioDeactivated,
      ])
      try await app.until("the system to end the call") { try await app.system.calls().isEmpty }
      app.expectNoMoreEvents()
    }
  }

  extension FakeMedia.Record {
    /// What the SDK asked of the media, without the call.
    enum Kind: Hashable {
      case prepare, activate, deactivate
    }

    var kind: Kind {
      switch self {
      case .prepare: .prepare
      case .activate: .activate
      case .deactivate: .deactivate
      }
    }
  }
#endif
