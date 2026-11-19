#if os(iOS) && targetEnvironment(simulator)
  import AVFAudio
  import CKSimProtocol
  import Dispatch
  import Foundation
  import Synchronization
  import Testing
  import VoIPAudio
  import VoIPCore
  import VoIPLiveActivity
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
      try await app.expect([
        .performed(.end(id), .ended(.localDeclined)), .ended(id, .localDeclined),
      ])
      try await app.until("the system to end the call") { try await app.system.calls().isEmpty }
      #expect(await app.media.records.isEmpty)
      try await app.expectPushesFinished([pushID])
      app.expectNoMoreEvents()
    }

    @Test func journalAndStatusShareTheSDKLifecycleWithARingRelativeAnswer() async throws {
      let app = try await App()
      defer { app.stop() }
      let id = newCallID("timed-answer")
      let uuid = deviceUUID(for: id)
      let push = try await app.system.pushIncomingCall(id)
      try await app.expect([.presented(id)])
      try await Task.sleep(for: .milliseconds(150))
      try await app.system.answer(uuid, afterMS: 400)
      try await app.expect([.performed(.answer(id), .connecting), .audioActivated])
      await app.client.receive(.connected, for: id, eventID: EventID(rawValue: "connected-\(id)"))
      try await app.until("the SDK to connect") { app.call(id)?.status == .connected }
      await app.client.receive(.endedRemotely, for: id, eventID: EventID(rawValue: "ended-\(id)"))
      try await app.expect([.ended(id, .endedRemotely), .audioDeactivated])
      let history = try await app.system.snapshot().retainedCalls
      let call = try #require(history.first { $0.callID == id.rawValue })
      #expect(call.uuid == uuid && call.state == .ended && call.endReason == "endedRemotely")
      let answer = try #require(call.answeredAtMS)
      let connected = try #require(call.connectedAtMS)
      let ended = try #require(call.endedAtMS)
      let reported = try #require(call.reportedAtMS)
      #expect(answer >= reported + 399)
      #expect(connected >= answer && ended >= connected)
      let events = try await app.system.journal().filter { $0.callUUID == uuid.uuidString }
      #expect(events.contains { $0.event == "sdk.accept" })
      #expect(events.contains { $0.event == "sdk.connected" })
      #expect(events.contains { $0.event == "sdk.ended" && $0.reason == "endedRemotely" })
      #expect(try await app.system.calls().isEmpty)
      try await app.expectPushesFinished([push])
      app.expectNoMoreEvents()
    }

    @Test func endingBeforeTheScheduledAnswerCancelsIt() async throws {
      let app = try await App()
      defer { app.stop() }
      let id = newCallID("cancel-timed-answer")
      let uuid = deviceUUID(for: id)
      let invite = try await app.system.pushIncomingCall(id)
      try await app.expect([.presented(id)])
      try await app.system.answer(uuid, afterMS: 1000)
      let end = try await app.system.pushCallEnded(id, reason: "remoteEnded")
      try await app.expect([.ended(id, .endedRemotely)])
      try await app.until("the scheduled answer to be cancelled") {
        try await app.system.journal().contains {
          $0.event == "answer.cancelled" && $0.callUUID == uuid.uuidString
        }
      }
      #expect(await app.media.records.isEmpty)
      try await app.expectPushesFinished([invite, end])
      app.expectNoMoreEvents()
    }

    @Test func answeredElsewhereBecomesAPreview() async throws {
      let app = try await App()
      defer { app.stop() }
      let id = newCallID("elsewhere")
      let invite = try await app.system.pushIncomingCall(id)
      try await app.expect([.presented(id)])

      // The server tells this device with another VoIP push, which the SDK reports with a
      // throwaway call that it ends at once.
      let ended = try await app.system.pushCallEnded(id, reason: "answeredElsewhere")
      try await app.expect([.previewStarted(id, .answeredElsewhere)])
      try await app.until("the system to end the calls") { try await app.system.calls().isEmpty }
      try await app.until("the call to become a preview") {
        app.call(id)?.status == .previewing(.answeredElsewhere)
      }
      #expect(await app.media.records.isEmpty)
      try await app.expectPushesFinished([invite, ended])
      try await app.expectReportedWithAThrowawayCall(ended, notAs: id)
      app.expectNoMoreEvents()
    }

    @Test func repeatedAndEndedPushesForAConnectedCallSurviveReportingEnforcement() async throws {
      let app = try await App()
      defer { app.stop() }
      let id = newCallID("connected")
      let invite = try await app.system.pushIncomingCall(id)
      try await app.expect([.presented(id)])
      try await app.system.perform(.answer(deviceUUID(for: id)))
      try await app.expect([.performed(.answer(id), .connecting), .audioActivated])
      await app.client.receive(.connected, for: id, eventID: EventID(rawValue: "connected-\(id)"))
      try await app.until("the call to connect") { app.call(id)?.status == .connected }

      let repeated = try await app.system.pushIncomingCall(id)
      try await app.expectPushesFinished([invite, repeated])
      try await app.expectReportedWithAThrowawayCall(repeated, notAs: id)
      #expect(app.call(id)?.status == .connected)
      #expect(await app.media.records.map(\.kind) == [.prepare, .activate])
      app.expectNoMoreEvents()

      // The push must be reported, as in the background, although it brings no call to present.
      let ended = try await app.system.pushCallEnded(id, reason: "remoteEnded")
      try await app.expect([.ended(id, .endedRemotely), .audioDeactivated])
      try await app.until("the system to end the calls") { try await app.system.calls().isEmpty }
      #expect(await app.media.records.map(\.kind) == [.prepare, .activate, .deactivate])
      try await app.expectPushesFinished([invite, repeated, ended])
      try await app.expectReportedWithAThrowawayCall(ended, notAs: id)
      // Both measured budgets have passed; the same process still answers its mailbox.
      try await Task.sleep(for: .seconds(31))
      #expect(try await app.system.calls().isEmpty)
      app.expectNoMoreEvents()
    }

    @Test func delayedDuplicateInvitesRingOnceAndReportEveryCopy() async throws {
      let app = try await App()
      defer { app.stop() }
      let id = newCallID("delivery-faults")
      let request = try await app.system.pushIncomingCall(
        id, delivery: PushDeliveryFaults(delayMS: 100, duplicate: 2, spacingMS: 100))
      try await app.expect([.presented(id)])
      let scheduled = try await app.system.journal().filter {
        $0.event == "push.scheduled" && $0.requestID == request.uuidString
      }
      let ids = try scheduled.map { try #require($0.pushID.flatMap(UUID.init(uuidString:))) }
      #expect(ids.count == 3 && Set(ids).count == 3)
      try await app.expectPushesFinished(ids)
      for repeated in ids.dropFirst() {
        try await app.expectReportedWithAThrowawayCall(repeated, notAs: id)
      }
      #expect(try await app.system.calls().map(\.uuid) == [deviceUUID(for: id)])
      #expect(app.call(id)?.status == .ringing)
      #expect(await app.media.records.isEmpty)
      try await app.system.perform(.decline(deviceUUID(for: id)))
      try await app.expect([
        .performed(.end(id), .ended(.localDeclined)), .ended(id, .localDeclined),
      ])
      try await app.until("the call to leave the call screen") {
        try await app.system.calls().isEmpty
      }
      app.expectNoMoreEvents()
    }

    @Test func aSecondCallIDFromTheSameCallerLeavesNoGhostCall() async throws {
      let app = try await App()
      defer { app.stop() }
      let first = newCallID("first-invite")
      let second = newCallID("second-invite")
      let invite = try await app.system.pushIncomingCall(first)
      try await app.expect([.presented(first)])
      // Same caller, different server call ID: this is another call, not a repeat of the first.
      let another = try await app.system.pushIncomingCall(second)
      try await app.expect([.presented(second)])
      let firstEnded = try await app.system.pushCallEnded(first, reason: "remoteEnded")
      try await app.expect([.ended(first, .endedRemotely)])
      try await app.until("only the second call to remain on the call screen") {
        try await app.system.calls().map(\.uuid) == [deviceUUID(for: second)]
      }
      #expect(app.call(second)?.status == .ringing)
      let secondEnded = try await app.system.pushCallEnded(second, reason: "remoteEnded")
      try await app.expect([.ended(second, .endedRemotely)])
      try await app.until("all calls to leave the call screen") {
        try await app.system.calls().isEmpty
      }
      try await app.expectPushesFinished([invite, another, firstEnded, secondEnded])
      try await app.expectReportedWithAThrowawayCall(firstEnded, notAs: first)
      try await app.expectReportedWithAThrowawayCall(secondEnded, notAs: second)
      #expect(await app.media.records.isEmpty)
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
      try await app.until("the call to end") { app.client.calls.isEmpty }
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
      try await app.until("the call to become a preview") {
        app.call(id)?.status == .previewing(.filtered(.doNotDisturb))
      }
      #expect(await app.media.records.isEmpty)
      try await app.expectPushesFinished([pushID])
      app.expectNoMoreEvents()
    }

    @Test func filteredCallStartsACallPreviewsLiveActivity() async throws {
      let center = FakeLiveActivityCenter()
      let previews = CallPreviewActivities(center: center)
      var activityEvents = previews.events().makeAsyncIterator()
      let app = try await App(observers: [previews])
      defer { app.stop() }
      try await app.system.filterIncomingCalls(.doNotDisturb)
      let id = newCallID("previewed")
      let pushID: UUID
      do {
        pushID = try await app.system.pushIncomingCall(id, metadata: ["room": .string("room-1")])
        try await app.expect([.previewStarted(id, .filtered(.doNotDisturb))])
      } catch {
        try await app.system.filterIncomingCalls(.none)
        throw error
      }
      try await app.system.filterIncomingCalls(.none)
      #expect(await activityEvents.next() == .started(id))
      guard case .request(_, let attributes, let state, _)? = center.records.first else {
        Issue.record("The observer didn't start a Live Activity")
        return
      }
      #expect(attributes.callID == id)
      #expect(attributes.parties.map(\.displayName) == ["Alice"])
      #expect(attributes.metadata == ["room": "room-1"])
      #expect(state.status == .filtered)
      #expect(state.isJoinable)

      await app.client.receive(.endedRemotely, for: id, eventID: EventID(rawValue: "end-\(id)"))
      try await app.expect([.ended(id, .endedRemotely)])
      #expect(await activityEvents.next() == .ended(id))
      #expect(center.activities.isEmpty)
      guard case .end(_, let final?, .after(.seconds(120)))? = center.records.last else {
        Issue.record("The observer didn't end the Live Activity with its final state")
        return
      }
      #expect(final.status == .ended)
      try await app.expectPushesFinished([pushID])
      app.expectNoMoreEvents()
    }

    @Test(arguments: [
      JoinFailure.ended, .refused, .frameworkReset, .failed(.media),
    ])
    func failedOrEndedJoinSettlesWithItsCause(_ failure: JoinFailure) async throws {
      let resetFramework = FakeCallingFramework()
      let app: App
      if failure == .frameworkReset {
        // The runtime's reset control requires no pending actions. Use the framework fake
        // to deliver a reset while the join action is still pending.
        app = try await App(framework: resetFramework)
      } else {
        // The refusal case needs the Join to reach the framework's conversation-group limit.
        app = try await App(
          configuration: VoIPConfiguration(
            maximumCalls: 1, maximumParticipatingCalls: failure == .refused ? 2 : 1))
      }
      defer { app.stop() }
      let id = newCallID("join-failure")
      let caller = try Party(handle: Handle(kind: .generic, value: "alice"))
      _ = await app.client.report(
        IncomingCall(
          id: id, parties: [caller],
          presentationPolicy: PresentationPolicy(incoming: .preview)))
      try await app.expect([.previewStarted(id, .policy)])

      let expectedBusyMedia: [FakeMedia.Record]?
      if failure == .refused {
        // An outgoing call reserves the only conversation group, so the framework refuses
        // another start request (including a join).
        let busy = newCallID("busy")
        let action = Action.start(OutgoingCall(id: busy, parties: [caller]))
        let request = Task { try await app.client.request(action) }
        try await app.expect([.startRequested(busy)])
        await app.client.confirmPlaced(busy)
        try await request.value
        try await app.expect([.performed(action, .dialing), .audioActivated])
        // The refused join must leave the busy call's media alone until that call ends.
        expectedBusyMedia = await app.media.records + [.deactivate]
        await #expect(throws: ActionError.self) {
          try await app.client.request(.join(id))
        }
        try await app.expect([.joinFailed(id, .policy, failure), .previewStarted(id, .policy)])
        _ = try await app.client.end(busy)
        try await app.expect([
          .performed(.end(busy), .ended(.localEnded)), .ended(busy, .localEnded), .audioDeactivated,
        ])
      } else {
        expectedBusyMedia = nil
        try await app.client.request(.join(id))
        try await app.expect([.joinRequested(id)])
        switch failure {
        case .ended:
          let result = try await app.client.end(id)
          guard case .ended(let receipt) = result else {
            Issue.record("Expected a local End receipt")
            return
          }
          #expect(receipt.reason == .localEnded)
          try await app.expect([
            .performed(.end(id), .ended(.localEnded)), .ended(id, .localEnded),
          ])
          try await app.until("the system to remove the ended join") {
            guard app.call(id) == nil else { return false }
            return try await app.system.calls().isEmpty
          }
          app.expectNoMoreEvents()
          return
        case .frameworkReset:
          await resetFramework.send(.reset)
        case .failed:
          await setPreparationToFail(app.media)
          await app.client.confirmPlaced(id)
        case .refused:
          Issue.record("Refusal is handled before the join is performed")
        }
        try await app.expect([.joinFailed(id, .policy, failure), .previewStarted(id, .policy)])
      }
      try await app.until("the call to return to its preview") {
        app.call(id)?.status == .previewing(.policy)
      }
      try await app.until("the system to remove the calls") { try await app.system.calls().isEmpty }
      let mediaRecords = await app.media.records
      if let expectedBusyMedia {
        #expect(mediaRecords == expectedBusyMedia)
      } else {
        #expect(mediaRecords.allSatisfy { $0.kind == .prepare })
      }
      app.expectNoMoreEvents()
    }

    @VoIPActor
    private func setPreparationToFail(_ media: FakeMedia) {
      media.preparation = .fail
    }

    @Test func joinsAPreviewThatTheServersStartedBeforeTheAppRan() async throws {
      let id = newCallID("joined")
      let center = FakeLiveActivityCenter()
      let caller = try Party(
        handle: Handle(kind: .phoneNumber, value: "+14155550123"), displayName: "Alice")
      let activity = center.startFromPush(
        CallPreviewAttributes(callID: id, parties: [caller], metadata: ["room": "room-1"]),
        state: CallPreviewAttributes.ContentState(
          status: .policy, startedAt: .now, statusText: "Your assistant is answering",
          isJoinable: true))
      let previews = CallPreviewActivities(center: center)
      let app = try await App(observers: [previews])
      defer { app.stop() }

      // The client doesn't know the call, so joining creates it from the preview, without a
      // call preview event for a call notifier to post for.
      try await previews.join(id)
      try await app.expect([.joinRequested(id)])
      try await app.until("the call to carry its metadata") {
        app.call(id)?.metadata == ["room": "room-1"]
      }
      await app.client.confirmPlaced(id)
      try await app.expect([.performed(.join(id), .connecting), .audioActivated])
      try await app.until("the preview to end") { center.activities.isEmpty }
      #expect(center.records == [.end(activity, nil, .immediate)])

      try await app.client.request(.end(id))
      try await app.expect([
        .performed(.end(id), .ended(.localEnded)), .ended(id, .localEnded), .audioDeactivated,
      ])
      try await app.until("the system to end the call") { try await app.system.calls().isEmpty }
      app.expectNoMoreEvents()
    }

    @Test func outgoingCallConnectsAndEndsHere() async throws {
      let app = try await App()
      defer { app.stop() }
      let id = newCallID("outgoing")
      let bob = try Party(handle: Handle(kind: .phoneNumber, value: "+442071838750"))
      let action = Action.start(OutgoingCall(id: id, parties: [bob]))
      let request = Task { try await app.client.request(action) }
      try await app.expect([.startRequested(id)])
      #expect(try await app.system.calls().isEmpty)

      await app.client.confirmPlaced(id)
      try await request.value
      try await app.expect([.performed(action, .dialing), .audioActivated])
      #expect(try await app.system.calls().map(\.outgoing) == [true])
      await app.client.receive(.connected, for: id, eventID: EventID(rawValue: "connected-\(id)"))
      try await app.until("the call to connect") { app.call(id)?.status == .connected }
      try await app.until("the system to see the call connected") {
        try await app.system.calls().map(\.connected) == [true]
      }

      try await app.client.request(.end(id))
      try await app.expect([
        .performed(.end(id), .ended(.localEnded)), .ended(id, .localEnded), .audioDeactivated,
      ])
      try await app.until("the system to end the call") { try await app.system.calls().isEmpty }
      let uuid = deviceUUID(for: id).uuidString
      let settledEnds = try await app.system.journal().filter {
        $0.event == "action.settled" && $0.kind == "end" && $0.callUUID == uuid
      }
      #expect(settledEnds.map(\.fulfilled) == [true])
      app.expectNoMoreEvents()
    }

    @Test func outgoingCallTheAppCannotPlaceFails() async throws {
      let app = try await App()
      defer { app.stop() }
      let id = newCallID("not-placed")
      let bob = try Party(handle: Handle(kind: .phoneNumber, value: "+442071838750"))
      let request = Task {
        try await app.client.request(.start(OutgoingCall(id: id, parties: [bob])))
      }
      try await app.expect([.startRequested(id)])

      // The app's servers refuse placement before the SDK submits the native Start.
      await app.client.confirmNotPlaced(id)
      await #expect(throws: ActionError.notAllowed(.ended(.failed(.notPlaced)))) {
        try await request.value
      }
      try await app.expect([.ended(id, .failed(.notPlaced))])
      try await app.until("the system to end the call") { try await app.system.calls().isEmpty }
      let uuid = deviceUUID(for: id).uuidString
      let starts = try await app.system.journal().filter {
        $0.event == "action.settled" && $0.kind == "start" && $0.callUUID == uuid
      }
      #expect(starts.isEmpty)
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
      try await app.until("the call to be muted") { app.call(id)?.isMuted == true }
      // With its only call on hold, the system deactivates audio, and activates it again when
      // the call resumes.
      try await app.system.perform(.hold(uuid, held: true, origin: .system))
      try await app.expect([.performed(.hold(id, onHold: true), .connected), .audioDeactivated])
      try await app.until("the call to be on hold") { app.call(id)?.isOnHold == true }
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
        .performed(.end(id), .ended(.localEnded)), .ended(id, .localEnded), .audioDeactivated,
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
        .performed(.end(waiting), .ended(.localEnded)), .ended(waiting, .localEnded),
        .audioDeactivated,
      ])
      try await app.until("the answered call to end") { app.call(waiting) == nil }
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
          .performed(.end(active), .ended(.localEnded)), .ended(active, .localEnded),
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

    @Test func aWaitingCallIsPresentedWhileItsReportLogIsBlocked() async throws {
      let (active, waiting) = (newCallID("logging-active"), newCallID("logging-waiting"))
      let entered = Mutex(false)
      let release = DispatchSemaphore(value: 0)
      defer { release.signal() }

      // Keep the synchronous log sink blocked until the report has reached the SDK and PushKit.
      let reports = IncomingReportLog { id in
        guard id == waiting else { return }
        entered.withLock { $0 = true }
        release.wait()
      }
      let app = try await App(reports: reports)
      defer { app.stop() }
      let pushes = try await answerAndConnect(active, thenRing: waiting, in: app)
      try await app.until("the waiting call's adapter log to begin") { entered.withLock { $0 } }
      #expect(reports.waitTimedOut(for: waiting) == false)
      try await app.expectPushesFinished(pushes)

      await app.client.receive(
        .endedRemotely, for: waiting, eventID: EventID(rawValue: "end-\(waiting)"))
      try await app.expect([.ended(waiting, .endedRemotely)])
      await app.client.receive(
        .endedRemotely, for: active, eventID: EventID(rawValue: "end-\(active)"))
      try await app.expect([.ended(active, .endedRemotely), .audioDeactivated])
      try await app.until("both system calls to end") { try await app.system.calls().isEmpty }
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
      try await app.expect([
        .performed(.end(next), .ended(.localDeclined)), .ended(next, .localDeclined),
      ])
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
