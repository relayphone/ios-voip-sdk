import Testing
import VoIPTesting

@testable import VoIPCore

extension EngineTests {
  /// Every path a call takes through the engine, from the app's and the system's side.
  @Suite("Calls")
  @MainActor
  struct Calls {
    @Test func incomingCallIsAnsweredConnectsAndEndsRemotely() async throws {
      let h = try Harness()
      try await h.ring()
      #expect(await h.push.finished == [.incoming(ringingCall, eventID: e1)])
      await h.until { $0.calls.map(\.status) == [.ringing] }

      let answer = try await h.answer()
      await h.framework.send(.audioActivated)
      #expect(try await h.next() == .audioActivated)
      await h.client.receive(.connected, for: callID, eventID: e2)
      await h.until { $0.calls.map(\.status) == [.connected] && $0.isAudioActive }

      await h.client.receive(.endedRemotely, for: callID, eventID: e3)
      #expect(try await h.next() == .ended(callID, .endedRemotely))
      #expect(
        await h.reported() == [
          .report(callID), .other(.fulfill(answer)), .ended(callID, .endedRemotely),
        ])
      let media = await h.media.records
      #expect(media.count == 2)
      #expect(media.first.flatMap(\.preparedCall)?.id == callID)
      #expect(media.last == .activate)
      await h.until { $0.calls.isEmpty }
      #expect(await h.framework.configuration == VoIPConfiguration())
    }

    @Test func appAnswersRingingCall() async throws {
      let h = try Harness()
      try await h.ring()
      try await h.client.request(.answer(callID))
      #expect(try await h.next() == .performed(.answer(callID), .connecting))
      let answer = try await h.lastActionID()
      let records = await h.records
      #expect(records.count == 3)
      #expect(records.dropFirst().first?.requested == .answer(callID))
      #expect(records.last == .fulfill(answer))
    }

    @Test(arguments: [false, true])
    func declineEndsRingingCall(fromApp: Bool) async throws {
      let h = try Harness()
      try await h.ring()
      if fromApp {
        try await h.client.request(.end(callID))
      } else {
        await h.framework.perform(.end(callID))
      }
      #expect(
        try await h.next(2) == [
          .performed(.end(callID), .ended(.endedHere)), .ended(callID, .endedHere),
        ])
      let decline = try await h.lastActionID()
      #expect(await h.records.last == .fulfill(decline))
      #expect(await h.reported().contains { if case .ended = $0 { true } else { false } } == false)
    }

    @Test(arguments: [true, false])
    func callAnsweredElsewhereWhileRinging(previews: Bool) async throws {
      let policy = PresentationPolicy(previewsCallsAnsweredElsewhere: previews)
      let h = try Harness(configuration: VoIPConfiguration(presentationPolicy: policy))
      try await h.ring()
      await h.client.receive(.answeredElsewhere, for: callID, eventID: e2)
      let expected: Seen =
        previews
        ? .previewStarted(callID, .answeredElsewhere) : .ended(callID, .answeredElsewhere)
      #expect(try await h.next() == expected)
      #expect(await h.reported() == [.report(callID), .ended(callID, .answeredElsewhere)])
    }

    @Test(arguments: [true, false])
    func filteredCall(previews: Bool) async throws {
      let policy = PresentationPolicy(previewsFilteredCalls: previews)
      let h = try Harness(configuration: VoIPConfiguration(presentationPolicy: policy))
      let framework = h.framework
      await onVoIPActor { framework.presentationOutcome = .filtered(.doNotDisturb) }
      await h.deliver(.incoming(ringingCall, eventID: e1))
      let expected: Seen =
        previews
        ? .previewStarted(callID, .filtered(.doNotDisturb))
        : .ended(callID, .filtered(.doNotDisturb))
      #expect(try await h.next() == expected)
      #expect(await h.reported() == [.report(callID)])
      #expect(await h.push.finished.count == 1)
      #expect(await h.media.records.isEmpty)
    }

    @Test(arguments: [PreviewReason.policy, .answeredElsewhere])
    func joinFromPreview(reason: PreviewReason) async throws {
      let h = try Harness()
      if reason == .policy {
        #expect(await h.client.report(incoming(callID, .preview)) == .previewed(.policy))
      } else {
        try await h.ring()
        await h.client.receive(.answeredElsewhere, for: callID, eventID: e2)
      }
      #expect(try await h.next() == .previewStarted(callID, reason))
      let before = await h.records.count

      try await h.client.request(.join(callID))
      #expect(try await h.next() == .joinRequested(callID))
      await h.client.confirmPlaced(callID)
      #expect(try await h.next() == .performed(.join(callID), .connecting))
      await h.client.receive(.connected, for: callID, eventID: e3)

      let join = try await h.lastActionID()
      let records = Array(await h.records.dropFirst(before))
      #expect(records.count == 4)
      let request = try #require(records.first?.requestedCall)
      #expect(records.first?.requested == .join(callID))
      #expect(request.parties == [alice])
      #expect(request.status == .connecting)
      #expect(
        records.dropFirst() == [
          .fulfill(join), .reportOutgoing(callID, connected: false),
          .reportOutgoing(callID, connected: true),
        ])
      await h.until { $0.calls.map(\.status) == [.connected] }
    }

    @Test func outgoingCallIsPlacedAndConnects() async throws {
      let h = try Harness()
      try await h.client.request(.start(outgoing))
      #expect(try await h.next() == .startRequested(callID))
      await h.client.confirmPlaced(callID)
      #expect(try await h.next() == .performed(.start(outgoing), .dialing))
      await h.client.receive(.connected, for: callID, eventID: e1)

      let start = try await h.lastActionID()
      let records = await h.records
      #expect(records.first?.requested == .start(outgoing))
      #expect(
        records.dropFirst() == [
          .fulfill(start), .reportOutgoing(callID, connected: false),
          .reportOutgoing(callID, connected: true),
        ])
      await h.until { $0.calls.first?.status == .connected && $0.calls.first?.connectedAt != nil }
    }

    @Test func callStartedFromSystemSurface() async throws {
      let h = try Harness()
      let start = await h.framework.perform(.start(outgoing))
      #expect(try await h.next() == .startRequested(callID))
      await h.client.confirmPlaced(callID)
      #expect(try await h.next() == .performed(.start(outgoing), .dialing))
      #expect(
        await h.records == [.fulfill(start), .reportOutgoing(callID, connected: false)])
    }

    @Test(arguments: [false, true])
    func outgoingCallTheAppCannotPlaceEnds(startedFromSystem: Bool) async throws {
      let h = try Harness()
      if startedFromSystem {
        await h.framework.perform(.start(outgoing))
      } else {
        try await h.client.request(.start(outgoing))
      }
      #expect(try await h.next() == .startRequested(callID))
      let start = try await h.lastActionID()

      await h.client.confirmNotPlaced(callID)
      #expect(try await h.next() == .ended(callID, .failed(.notPlaced)))
      #expect(
        await h.records.suffix(2) == [.fail(start), .reportEnded(callID, .failed(.notPlaced))])
      #expect(await h.media.records.isEmpty)
      await h.until { $0.calls.isEmpty }

      // The placement deadline was disarmed with the call.
      #expect(h.clock.pendingSleepCount == 0)
      h.clock.advance(by: Deadlines().placement)
      try await h.expectNoEvents()
    }

    @Test func callTheAppCannotJoinReturnsToItsPreview() async throws {
      let h = try Harness()
      _ = await h.client.report(incoming(callID, .preview))
      #expect(try await h.next() == .previewStarted(callID, .policy))
      try await h.client.request(.join(callID))
      #expect(try await h.next() == .joinRequested(callID))
      let join = try await h.lastActionID()

      await h.client.confirmNotPlaced(callID)
      #expect(try await h.next() == .previewStarted(callID, .policy))
      #expect(
        await h.records.suffix(2) == [.fail(join), .reportEnded(callID, .failed(.notPlaced))])
      #expect(await h.media.records.isEmpty)
      await h.until { $0.calls.map(\.status) == [.previewing(.policy)] }

      // The user can join again from the preview.
      try await h.client.request(.join(callID))
      #expect(try await h.next() == .joinRequested(callID))
    }

    @Test func appCanGiveUpBeforeTheSystemPerformsTheStart() async throws {
      let h = try Harness()
      let framework = h.framework
      await onVoIPActor { framework.requestResult = .accept }
      try await h.client.request(.start(outgoing))

      await h.client.confirmNotPlaced(callID)
      #expect(try await h.next() == .ended(callID, .failed(.notPlaced)))
      #expect(await h.records.last == .reportEnded(callID, .failed(.notPlaced)))

      // The system performs the start late, and the SDK fails it.
      let start = await h.framework.perform(.start(outgoing))
      #expect(await h.records.last == .fail(start))
      try await h.expectNoEvents()
    }

    @Test func confirmingNotPlacedLeavesOtherCallsAlone() async throws {
      let h = try Harness()
      await h.client.confirmNotPlaced(callID)
      try await h.client.request(.start(outgoing))
      #expect(try await h.next() == .startRequested(callID))
      await h.client.confirmPlaced(callID)
      #expect(try await h.next() == .performed(.start(outgoing), .dialing))
      let before = await h.records

      // A call the app placed, and a call this device doesn't know, are unaffected.
      await h.client.confirmNotPlaced(callID)
      await h.client.confirmNotPlaced(otherCallID)
      try await h.expectNoEvents()
      #expect(await h.records == before)
      let engine = h.client.engine
      #expect(await onVoIPActor { engine.states[callID]?.call.status } == .dialing)
    }

    @Test func appEndsConnectedCall() async throws {
      let h = try Harness()
      try await h.connect()
      try await h.client.request(.end(callID))
      #expect(
        try await h.next(2) == [
          .performed(.end(callID), .ended(.endedHere)), .ended(callID, .endedHere),
        ])
      let end = try await h.lastActionID()
      #expect(await h.records.last == .fulfill(end))
      await h.until { $0.calls.isEmpty }
    }

    @Test func performsActionsWithoutSubscriber() async throws {
      let h = try Harness(subscribe: false)
      await h.deliver(.incoming(ringingCall, eventID: e1))
      let answer = await h.framework.perform(.answer(callID))
      await h.client.receive(.connected, for: callID, eventID: e2)
      await h.until { $0.calls.map(\.status) == [.connected] }
      #expect(await h.records.contains(.fulfill(answer)))

      h.subscribe()
      await h.client.receive(.endedRemotely, for: callID, eventID: e3)
      #expect(try await h.next() == .ended(callID, .endedRemotely))
    }

    @Test func audioActivationStartsMediaOnceForEveryCall() async throws {
      let h = try Harness()
      try await h.ring()
      try await h.ring(IncomingCall(id: otherCallID, parties: [alice]), eventID: e2)
      try await h.answer(callID)
      try await h.answer(otherCallID)

      await h.framework.send(.audioActivated)
      #expect(try await h.next() == .audioActivated)
      #expect(await h.media.records.filter { $0 == .activate }.count == 1)
      await h.until { $0.isAudioActive }

      // Both calls stop waiting for audio, so only their connect deadline remains.
      let deadlines = Deadlines()
      h.clock.advance(by: deadlines.audioActivation)
      try await h.expectNoEvents()
      h.clock.advance(by: deadlines.connect - deadlines.audioActivation)
      #expect(
        Set(try await h.next(2)) == [
          .ended(callID, .failed(.connectTimedOut)),
          .ended(otherCallID, .failed(.connectTimedOut)),
        ])

      await h.framework.send(.audioDeactivated)
      #expect(try await h.next() == .audioDeactivated)
      #expect(await h.media.records.last == .deactivate)
      await h.until { !$0.isAudioActive }
    }

    @Test func frameworkResetEndsTheCallsItPresents() async throws {
      let h = try Harness()
      try await h.ring()
      _ = await h.client.report(incoming(otherCallID, .preview))
      #expect(try await h.next() == .previewStarted(otherCallID, .policy))
      let framework = h.framework
      await onVoIPActor { framework.requestResult = .accept }
      try await h.client.request(.join(otherCallID))

      await h.framework.send(.reset)
      #expect(
        try await h.next(2) == [
          .ended(callID, .failed(.frameworkReset)), .previewStarted(otherCallID, .policy),
        ])
      try await h.expectNoEvents()
      #expect(await h.reported().allSatisfy { if case .ended = $0 { false } else { true } })
    }

    @Test func actionTheSystemStopsWaitingForFails() async throws {
      let h = try Harness()
      try await h.ring()
      let media = h.media
      await onVoIPActor { media.preparation = .wait }
      let answer = await h.framework.perform(.answer(callID))
      await h.framework.send(.actionTimedOut(answer))
      #expect(try await h.next() == .ended(callID, .failed(.actionTimedOut)))
      #expect(
        await h.reported().suffix(2) == [
          .other(.fail(answer)), .ended(callID, .failed(.actionTimedOut)),
        ])
    }

    @Test func secondStartThrowsWhileAClientRuns() throws {
      var first: Harness? = try Harness()
      #expect(first != nil)
      #expect(throws: StartupError.alreadyStarted) {
        _ = try VoIPClient.start(framework: FakeCallingFramework(), media: FakeMedia())
      }
      first = nil
      _ = try VoIPClient.start(framework: FakeCallingFramework(), media: FakeMedia())
    }

    @Test func requestErrors() async throws {
      let h = try Harness()
      await #expect(throws: ActionError.unknownCall) {
        try await h.client.request(.answer(callID))
      }
      _ = await h.client.report(incoming(callID, .preview))
      #expect(try await h.next() == .previewStarted(callID, .policy))
      await #expect(throws: ActionError.notAllowed(.previewing(.policy))) {
        try await h.client.request(.answer(callID))
      }
      await #expect(throws: ActionError.notAllowed(.previewing(.policy))) {
        try await h.client.request(.start(outgoing))
      }
      await #expect(throws: ActionError.unsupported) {
        try await h.client.request(.merge(callID, with: otherCallID))
      }
      #expect(await h.records.isEmpty)
    }

    @Test func refusedStartEndsTheCall() async throws {
      let h = try Harness()
      let framework = h.framework
      await onVoIPActor { framework.requestResult = .refuse(.refused) }
      await #expect(throws: ActionError.refused) {
        try await h.client.request(.start(outgoing))
      }
      #expect(try await h.next() == .ended(callID, .failed(.refused)))
    }

    @Test func refusedJoinReturnsToPreview() async throws {
      let h = try Harness()
      _ = await h.client.report(incoming(callID, .preview))
      #expect(try await h.next() == .previewStarted(callID, .policy))
      let framework = h.framework
      await onVoIPActor { framework.requestResult = .refuse(.refused) }
      await #expect(throws: ActionError.refused) {
        try await h.client.request(.join(callID))
      }
      #expect(try await h.next() == .previewStarted(callID, .policy))
    }

    @Test func reportReturnsTheFirstOutcome() async throws {
      let h = try Harness()
      let framework = h.framework
      await onVoIPActor { framework.presentationOutcome = .filtered(.blockList) }
      #expect(await h.client.report(ringingCall) == .previewed(.filtered(.blockList)))
      #expect(try await h.next() == .previewStarted(callID, .filtered(.blockList)))
      await onVoIPActor { framework.presentationOutcome = .presented }
      #expect(await h.client.report(ringingCall) == .previewed(.filtered(.blockList)))

      // A call preview, and a call that doesn't appear, aren't reported to the framework.
      #expect(await h.client.report(incoming(otherCallID, .preview)) == .previewed(.policy))
      #expect(try await h.next() == .previewStarted(otherCallID, .policy))
      #expect(await h.client.report(incoming(otherCallID, .ring)) == .previewed(.policy))
      #expect(await h.client.report(incoming(CallID(rawValue: "call-3"), .none)) == .notShown)
      try await h.expectNoEvents()
      #expect(await h.reported() == [.report(callID)])
    }

    @Test(arguments: [
      (PresentationOutcome.presented, true, PresentationOutcome.presented),
      (.filtered(.doNotDisturb), true, .previewed(.filtered(.doNotDisturb))),
      (.filtered(.doNotDisturb), false, .filtered(.doNotDisturb)),
      (.refused(.refused), true, .refused(.refused)),
    ])
    func reportReturnsHowTheCallAppears(
      system: PresentationOutcome, previewsFilteredCalls: Bool, expected: PresentationOutcome
    ) async throws {
      let policy = PresentationPolicy(previewsFilteredCalls: previewsFilteredCalls)
      let h = try Harness(configuration: VoIPConfiguration(presentationPolicy: policy))
      let framework = h.framework
      await onVoIPActor { framework.presentationOutcome = system }
      #expect(await h.client.report(ringingCall) == expected)
    }

    @Test func reportOfACallAnsweredElsewhereWhileReportingReturnsAPreview() async throws {
      let h = try Harness()
      let framework = h.framework
      await onVoIPActor { framework.presentationOutcome = nil }
      await h.deliver(.incoming(ringingCall, eventID: e1))
      await h.client.receive(.answeredElsewhere, for: callID, eventID: e2)
      async let outcome = h.client.report(ringingCall)
      await onVoIPActor { framework.completeReports(of: callID, with: .presented) }
      #expect(await outcome == .previewed(.answeredElsewhere))
      #expect(try await h.next() == .previewStarted(callID, .answeredElsewhere))
    }

    @Test func reportWaitsForTheFirstReport() async throws {
      let h = try Harness()
      let framework = h.framework
      await onVoIPActor { framework.presentationOutcome = nil }
      await h.deliver(.incoming(ringingCall, eventID: e1))
      async let repeated = h.client.report(ringingCall)
      await onVoIPActor { framework.completeReports(of: callID, with: .presented) }
      #expect(await repeated == .presented)
      #expect(try await h.next() == .presented(callID))
    }

    @Test func reportBeyondCapacityEndsTheCall() async throws {
      let h = try Harness(configuration: VoIPConfiguration(maximumCalls: 1))
      try await h.ring()
      let second = IncomingCall(id: otherCallID, parties: [alice])
      #expect(await h.client.report(second) == .refused(.atCapacity))
      #expect(try await h.next() == .ended(otherCallID, .failed(.atCapacity)))
      // Call previews don't count, and aren't limited.
      #expect(
        await h.client.report(incoming(CallID(rawValue: "call-3"), .preview))
          == .previewed(.policy))
      #expect(await h.reported() == [.report(callID)])
    }
  }
}

extension FakeCallingFramework.Record {
  /// The action of a request.
  var requested: Action? {
    if case .request(let action, _) = self { action } else { nil }
  }

  /// The call a request carried.
  var requestedCall: Call? {
    if case .request(_, let call) = self { call } else { nil }
  }
}

extension FakeMedia.Record {
  var preparedCall: Call? {
    if case .prepare(let call) = self { call } else { nil }
  }
}
