#if os(iOS) && targetEnvironment(simulator)
  import AVFAudio
  import CKSimProtocol
  import Foundation
  import Testing
  import VoIPAudio
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

    @Test func outgoingCallTheAppCannotPlaceFails() async throws {
      let app = try await App()
      defer { app.stop() }
      let id = newCallID("not-placed")
      let bob = try Party(handle: Handle(kind: .phoneNumber, value: "+442071838750"))
      try await app.client.request(.start(OutgoingCall(id: id, parties: [bob])))
      try await app.expect([.startRequested(id)])

      // The app's servers refuse the call, so the app fails it rather than waiting for the
      // placement deadline, and the system's start fails with it.
      await app.client.confirmNotPlaced(id)
      try await app.expect([.ended(id, .failed(.notPlaced))])
      try await app.until("the system to end the call") { try await app.system.calls().isEmpty }
      let uuid = deviceUUID(for: id).uuidString
      let starts = try await app.system.journal().filter {
        $0.event == "action.settled" && $0.kind == "start" && $0.callUUID == uuid
      }
      #expect(starts.map(\.fulfilled) == [false])
      #expect(await app.media.records.isEmpty)
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

    @Test func holdAndAcceptAWaitingCall() async throws {
      let app = try await App()
      defer { app.stop() }
      let (active, waiting) = (newCallID("held"), newCallID("waiting"))
      let pushIDs = try await answerAndConnect(active, thenRing: waiting, in: app)

      // The system holds the active call and answers the waiting one in one transaction. The
      // held call gives up audio before the answered one takes it.
      try await app.system.perform(
        .holdAndAccept(deviceUUID(for: waiting), active: deviceUUID(for: active)))
      try await app.expect(
        interleaving: [
          .performed(.hold(active, onHold: true), .connected),
          .performed(.answer(waiting), .connecting),
        ], [.audioDeactivated, .audioActivated])
      await app.client.receive(
        .connected, for: waiting, eventID: EventID(rawValue: "connected-\(waiting)"))
      try await app.until("the answered call to connect") {
        app.call(waiting)?.status == .connected
      }
      try await app.until("the system to hold one call and connect the other") {
        let calls = try await app.system.calls().filter(\.connected)
        return Dictionary(uniqueKeysWithValues: calls.map { ($0.uuid, $0.held) }) == [
          deviceUUID(for: active): true, deviceUUID(for: waiting): false,
        ]
      }

      // Ending the answered call leaves the held one on hold until the user takes it off hold.
      try await app.system.perform(.end(deviceUUID(for: waiting)))
      try await app.expect([
        .performed(.end(waiting), .ended(.endedHere)), .ended(waiting, .endedHere),
        .audioDeactivated,
      ])
      #expect(app.call(active)?.isOnHold == true)
      try await app.system.perform(.hold(deviceUUID(for: active), held: false, origin: .system))
      try await app.expect([.performed(.hold(active, onHold: false), .connected), .audioActivated])

      await app.client.receive(
        .endedRemotely, for: active, eventID: EventID(rawValue: "end-\(active)"))
      try await app.expect([.ended(active, .endedRemotely), .audioDeactivated])
      try await app.until("the system to end the calls") { try await app.system.calls().isEmpty }
      #expect(
        await app.media.records.map(\.kind).filter { $0 != .prepare } == [
          .activate, .deactivate, .activate, .deactivate, .activate, .deactivate,
        ])
      try await app.expectPushesFinished(pushIDs)
      app.expectNoMoreEvents()
    }

    @Test func endAndAcceptAWaitingCall() async throws {
      let app = try await App()
      defer { app.stop() }
      let (active, waiting) = (newCallID("ended"), newCallID("waiting"))
      let pushIDs = try await answerAndConnect(active, thenRing: waiting, in: app)

      // The system ends the active call and answers the waiting one in one transaction.
      try await app.system.perform(
        .endAndAccept(deviceUUID(for: waiting), active: deviceUUID(for: active)))
      try await app.expect(
        interleaving: [
          .performed(.end(active), .ended(.endedHere)), .ended(active, .endedHere),
          .performed(.answer(waiting), .connecting),
        ], [.audioDeactivated, .audioActivated])
      await app.client.receive(
        .connected, for: waiting, eventID: EventID(rawValue: "connected-\(waiting)"))
      try await app.until("the answered call to connect") {
        app.call(waiting)?.status == .connected
      }
      try await app.until("the system to keep only the answered call") {
        try await app.system.calls().map(\.uuid) == [deviceUUID(for: waiting)]
      }

      await app.client.receive(
        .endedRemotely, for: waiting, eventID: EventID(rawValue: "end-\(waiting)"))
      try await app.expect([.ended(waiting, .endedRemotely), .audioDeactivated])
      try await app.until("the system to end the call") { try await app.system.calls().isEmpty }
      #expect(
        await app.media.records.map(\.kind).filter { $0 != .prepare } == [
          .activate, .deactivate, .activate, .deactivate,
        ])
      try await app.expectPushesFinished(pushIDs)
      app.expectNoMoreEvents()
    }

    @Test func frameworkResetEndsEveryCall() async throws {
      let app = try await App()
      defer { app.stop() }
      let (active, waiting) = (newCallID("reset-active"), newCallID("reset-waiting"))
      var pushIDs = try await answerAndConnect(active, thenRing: waiting, in: app)

      // The system's call service restarts, which ends every call it presents and its audio.
      try await app.system.resetCallingFramework()
      try await app.expect(
        interleaving: [
          .ended(active, .failed(.frameworkReset)), .ended(waiting, .failed(.frameworkReset)),
        ], [.audioDeactivated])
      #expect(try await app.system.calls().isEmpty)
      try await app.until("the calls to end") { app.client.calls.isEmpty }

      // Calls ring again after the reset.
      let next = newCallID("after-reset")
      pushIDs.append(try await app.system.pushIncomingCall(next))
      try await app.expect([.presented(next)])
      try await app.system.perform(.decline(deviceUUID(for: next)))
      try await app.expect([.performed(.end(next), .ended(.endedHere)), .ended(next, .endedHere)])
      try await app.until("the system to end the call") { try await app.system.calls().isEmpty }
      try await app.expectPushesFinished(pushIDs)
      app.expectNoMoreEvents()
    }

    /// A media services reset after which the system doesn't activate audio again.
    ///
    /// The runtime can't restart the media services, so the journey posts the notification that
    /// the system posts, which carries nothing else. Audio interruptions aren't covered: from
    /// iOS 27 the system reports them with a deactivation context that only it can create.
    @Test func callWhoseAudioDoesNotRecoverFromAMediaServicesResetFails() async throws {
      let app = try await App(
        audio: AudioSessionAdapter(),
        configuration: VoIPConfiguration(deadlines: Deadlines(audioRecovery: .seconds(2))))
      defer { app.stop() }
      let id = newCallID("media-reset")
      let pushID = try await app.system.pushIncomingCall(id)
      try await app.expect([.presented(id)])
      try await app.system.perform(.answer(deviceUUID(for: id)))
      try await app.expect([.performed(.answer(id), .connecting), .audioActivated])
      await app.client.receive(.connected, for: id, eventID: EventID(rawValue: "connected-\(id)"))
      try await app.until("the call to connect") { app.call(id)?.status == .connected }

      NotificationCenter.default.post(
        name: AVAudioSession.mediaServicesWereResetNotification,
        object: AVAudioSession.sharedInstance())
      try await app.expect([
        .mediaServicesReset, .ended(id, .failed(.audioRecoveryTimedOut)), .audioDeactivated,
      ])
      try await app.until("the system to end the call") { try await app.system.calls().isEmpty }
      #expect(await app.media.records.map(\.kind) == [.prepare, .activate, .deactivate])
      try await app.expectPushesFinished([pushID])
      app.expectNoMoreEvents()
    }

    @Test func coldLaunchFromAPushAnswersBeforeTheAppListens() async throws {
      let id = newCallID("cold")
      var pushID = UUID()
      // A VoIP push launches the app, and the user answers before the app's own code listens for
      // events, as when its JavaScript is still loading.
      let app = try await App(listening: false) {
        pushID = try await $0.pushIncomingCall(id)
      }
      defer { app.stop() }
      try await app.until("the call to ring") { app.call(id)?.status == .ringing }
      try await app.expectPushesFinished([pushID])
      try await app.system.perform(.answer(deviceUUID(for: id)))
      try await app.until("the system to activate audio") { app.client.isAudioActive }
      #expect(app.call(id)?.status == .connecting)
      #expect(await app.media.records.map(\.kind) == [.prepare, .activate])
      #expect(try await app.system.calls().map(\.connected) == [true])

      // Once its code has loaded, the app listens and finds the call in progress.
      app.listen()
      await app.client.receive(.connected, for: id, eventID: EventID(rawValue: "connected-\(id)"))
      try await app.until("the call to connect") { app.call(id)?.status == .connected }
      await app.client.receive(.endedRemotely, for: id, eventID: EventID(rawValue: "end-\(id)"))
      try await app.expect([.ended(id, .endedRemotely), .audioDeactivated])
      try await app.until("the system to end the call") { try await app.system.calls().isEmpty }
      app.expectNoMoreEvents()
    }

    /// Answers a pushed call from the call screen and connects it, then pushes another call,
    /// which waits.
    ///
    /// - Returns: The pushes' identifiers.
    private func answerAndConnect(
      _ active: CallID, thenRing waiting: CallID, in app: App
    ) async throws -> [UUID] {
      let first = try await app.system.pushIncomingCall(active)
      try await app.expect([.presented(active)])
      try await app.system.perform(.answer(deviceUUID(for: active)))
      try await app.expect([.performed(.answer(active), .connecting), .audioActivated])
      await app.client.receive(
        .connected, for: active, eventID: EventID(rawValue: "connected-\(active)"))
      try await app.until("the call to connect") { app.call(active)?.status == .connected }
      let second = try await app.system.pushIncomingCall(waiting, from: "+14155550199")
      try await app.expect([.presented(waiting)])
      return [first, second]
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
