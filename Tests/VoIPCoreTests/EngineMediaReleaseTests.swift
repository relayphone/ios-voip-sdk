import Testing
import VoIPTesting

@testable import VoIPCore

extension EngineTests {
  @Suite("Media release") @MainActor
  struct MediaReleaseTests {
    @Test(arguments: [true, false])
    func releaseAndDeactivationFollowTheirInputOrder(endsFirst: Bool) async throws {
      let h = try Harness()
      try await h.connect()
      if !endsFirst {
        await h.framework.send(.audioDeactivated)
        #expect(try await h.next() == .audioDeactivated)
      }
      await h.client.receive(.endedRemotely, for: callID, eventID: e3)
      #expect(try await h.next() == .ended(callID, .endedRemotely))
      if endsFirst {
        await h.framework.send(.audioDeactivated)
        #expect(try await h.next() == .audioDeactivated)
      }
      let records = await h.media.records
      let releasedCalls = records.compactMap(\.releasedCall)
      #expect(releasedCalls.count == 1)
      let released = try #require(releasedCalls.first)
      #expect(released.status == .ended(.endedRemotely))
      #expect(
        records.suffix(2)
          == (endsFirst ? [.release(released), .deactivate] : [.deactivate, .release(released)]))
      await h.framework.send(.audioDeactivated)
      #expect(try await h.next() == .audioDeactivated)
      #expect(await h.media.records.compactMap(\.releasedCall).count == 1)
    }

    @Test func answeredElsewhereReleasesBeforeARejoinOfTheSameCall() async throws {
      let h = try Harness()
      try await h.ring()
      try await h.answer()
      await h.client.receive(.answeredElsewhere, for: callID, eventID: e2)
      #expect(try await h.next() == .previewStarted(callID, .answeredElsewhere))
      #expect(
        await h.media.records.compactMap(\.releasedCall).map(\.status) == [
          .previewing(.answeredElsewhere)
        ])
      try await h.client.request(.join(callID))
      #expect(try await h.next() == .joinRequested(callID))
      await h.client.confirmPlaced(callID)
      #expect(try await h.next() == .performed(.join(callID), .connecting))
      await h.client.receive(.endedRemotely, for: callID, eventID: e3)
      #expect(try await h.next() == .ended(callID, .endedRemotely))
      #expect(await h.media.records.compactMap(\.releasedCall).count == 2)
    }

    @Test func failedJoinPreparationNeverReleases() async throws {
      let h = try Harness()
      let media = h.media
      await onVoIPActor { media.preparation = .fail }
      _ = await h.client.report(incoming(callID, .preview))
      #expect(try await h.next() == .previewStarted(callID, .policy))
      try await h.client.request(.join(callID))
      #expect(try await h.next() == .joinRequested(callID))
      await h.client.confirmPlaced(callID)
      #expect(try await h.next() == .joinFailed(callID, .policy, .failed(.media)))
      #expect(try await h.next() == .previewStarted(callID, .policy))
      #expect(await media.records.compactMap(\.releasedCall).isEmpty)
    }

    @Test func cancelledPreparationNeverReleases() async throws {
      let h = try Harness()
      let media = h.media
      await onVoIPActor { media.preparation = .wait }
      try await h.ring()
      await h.framework.perform(.answer(callID))
      await waitForPreparation(media)
      await h.client.receive(.answeredElsewhere, for: callID, eventID: e2)
      #expect(try await h.next() == .previewStarted(callID, .answeredElsewhere))
      await media.finishPreparing(callID, succeeded: true)
      #expect(await media.records.compactMap(\.releasedCall).isEmpty)
    }

    @Test func aSuccessfulJoinThatLaterFailsReleases() async throws {
      let h = try Harness()
      _ = await h.client.report(incoming(callID, .preview))
      #expect(try await h.next() == .previewStarted(callID, .policy))
      try await h.client.request(.join(callID))
      #expect(try await h.next() == .joinRequested(callID))
      await h.client.confirmPlaced(callID)
      #expect(try await h.next() == .performed(.join(callID), .connecting))
      h.clock.advance(by: Deadlines().audioActivation)
      #expect(try await h.next() == .ended(callID, .failed(.audioActivationTimedOut)))
      #expect(await h.media.records.compactMap(\.releasedCall).count == 1)
    }

    @Test @VoIPActor func aConformerCanUseTheDefaultRelease() {
      LegacyMedia().release(Call(id: callID, isIncoming: true, parties: [], status: .connecting))
    }
  }
}

@VoIPActor
private func waitForPreparation(_ media: FakeMedia) async {
  while !media.waitingCalls.contains(callID) { await Task.yield() }
}

private struct LegacyMedia: CallMedia {
  func prepare(_ call: Call) async throws {}
  func activate() {}
  func deactivate() {}
}

extension FakeMedia.Record {
  fileprivate var releasedCall: Call? {
    if case .release(let call) = self { call } else { nil }
  }
}
