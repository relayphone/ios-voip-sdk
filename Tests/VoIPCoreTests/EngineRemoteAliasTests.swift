import Testing
import VoIPCore
import VoIPTesting

extension EngineTests {
  @Suite("Remote aliases")
  @MainActor
  struct RemoteAliases {
    @Test func bufferedAliasEndWinsDuringAdmission() async throws {
      let h = try Harness()
      let alias = try #require(RemoteCallID(rawValue: "server-incoming"))
      let framework = h.framework
      await onVoIPActor { framework.presentationOutcome = nil }

      await h.client.receive(.endedRemotely, forRemote: alias, eventID: e1)
      await h.deliver(.incoming(ringingCall, eventID: e2))
      await h.client.receive(.declinedElsewhere, for: callID, eventID: e3)
      try await h.client.bindRemote(alias, to: callID)
      #expect(h.client.calls.isEmpty)
      #expect(try await h.client.end(callID) == .alreadyEnded(.endedRemotely))
      #expect(await h.reported() == [.report(callID)])

      await onVoIPActor { framework.completeReports(of: callID, with: .presented) }
      #expect(try await h.next() == .ended(callID, .endedRemotely))
      #expect(await h.reported() == [.report(callID), .ended(callID, .endedRemotely)])
      try await h.expectNoEvents()
    }

    @Test func deferredOutgoingUsesBothAliasesWithTheCanonicalID() async throws {
      let h = try Harness(configuration: VoIPConfiguration(outgoingMedia: .whenProvided))
      let server = try #require(RemoteCallID(rawValue: "server-outgoing"))
      let room = try #require(RemoteCallID(rawValue: "room-outgoing"))
      let request = try await h.beginStart(outgoing)
      await h.client.confirmPlaced(callID)
      try await request.value
      #expect(try await h.next() == .performed(.start(outgoing), .dialing))
      h.clock.advance(by: .seconds(12))

      try await h.client.bindRemote(server, to: callID)
      try await h.client.bindRemote(room, to: callID)
      #expect(h.client.calls.first?.id == callID)
      #expect(h.client.calls.first?.remoteIDs == [server, room])
      #expect(h.client.calls.first?.status == .dialing)
      #expect(await h.media.records.isEmpty)

      try await h.client.provideMedia(callID)
      await h.client.receive(.connected, forRemote: room, eventID: e1)
      await h.until { $0.calls.first?.status == .connected }
      await h.client.receive(.declinedElsewhere, for: callID, eventID: e1)
      await h.client.receive(.endedRemotely, forRemote: server, eventID: e2)
      #expect(try await h.next() == .ended(callID, .endedRemotely))
      #expect(await h.records.contains(.reportEnded(callID, .endedRemotely)))
      try await h.expectNoEvents()
    }

    @Test func aliasOwnershipCanMoveAfterEndWithoutReplayingAnEvent() async throws {
      let h = try Harness()
      // The same string can also be the canonical ID of a different call.
      let alias = try #require(RemoteCallID(rawValue: otherCallID.rawValue))
      await h.client.receive(.endedRemotely, forRemote: alias, eventID: e1)
      try await h.ring(IncomingCall(id: otherCallID, parties: [alice]), eventID: e2)
      try await h.ring(eventID: e3)

      try await h.client.bindRemote(alias, to: callID)
      #expect(try await h.next() == .ended(callID, .endedRemotely))
      try await h.client.bindRemote(alias, to: callID)
      try await h.client.bindRemote(alias, to: otherCallID)
      await h.client.receive(.endedRemotely, forRemote: alias, eventID: e1)
      try await h.expectNoEvents()
      #expect(h.client.calls.first { $0.id == otherCallID }?.status == .ringing)
    }

    @Test func rejectsAliasOwnedByAnotherReportingCall() async throws {
      let h = try Harness()
      let alias = try #require(RemoteCallID(rawValue: "shared"))
      let framework = h.framework
      await onVoIPActor { framework.presentationOutcome = nil }
      await h.deliver(.incoming(ringingCall, eventID: e1))
      try await h.client.bindRemote(alias, to: callID)
      try await h.client.bindRemote(alias, to: callID)
      await h.deliver(.incoming(IncomingCall(id: otherCallID, parties: [alice]), eventID: e2))
      await #expect(throws: ActionError.remoteIdentityConflict(alias)) {
        try await h.client.bindRemote(alias, to: otherCallID)
      }
      await h.client.receive(.endedRemotely, forRemote: alias, eventID: e3)
      await onVoIPActor {
        framework.completeReports(of: callID, with: .presented)
        framework.completeReports(of: otherCallID, with: .presented)
      }
      #expect(try await h.next(2) == [.ended(callID, .endedRemotely), .presented(otherCallID)])
    }

    @Test(arguments: [false, true])
    func aliasEndExpiresAcrossAdmission(bindBeforeExpiry: Bool) async throws {
      let h = try Harness(configuration: VoIPConfiguration(retention: .seconds(1)))
      let alias = try #require(RemoteCallID(rawValue: "expiring"))
      let framework = h.framework
      await onVoIPActor { framework.presentationOutcome = nil }
      await h.client.receive(.answeredElsewhere, forRemote: alias, eventID: e1)
      await h.deliver(.incoming(ringingCall, eventID: e2))
      if bindBeforeExpiry { try await h.client.bindRemote(alias, to: callID) }
      h.clock.advance(by: .seconds(1))
      if !bindBeforeExpiry { try await h.client.bindRemote(alias, to: callID) }
      await onVoIPActor { framework.completeReports(of: callID, with: .presented) }
      #expect(try await h.next() == .presented(callID))
      #expect(await h.reported() == [.report(callID)])
    }

    @Test func bufferEvictsOldestUnresolvedEvent() async throws {
      var configuration = VoIPConfiguration()
      configuration.eventHistoryLimit = 1
      let h = try Harness(configuration: configuration)
      let olderAlias = try #require(RemoteCallID(rawValue: "old"))
      let newerAlias = try #require(RemoteCallID(rawValue: "new"))
      await h.client.receive(.declinedElsewhere, forRemote: olderAlias, eventID: e1)
      await h.client.receive(.endedRemotely, forRemote: newerAlias, eventID: e2)
      try await h.ring(eventID: e3)
      try await h.client.bindRemote(olderAlias, to: callID)
      #expect(h.client.calls.first?.status == .ringing)
      try await h.client.bindRemote(newerAlias, to: callID)
      #expect(try await h.next() == .ended(callID, .endedRemotely))
    }

    @Test func byteDistinctIDsStayDistinctThroughRoutingAndDeduplication() async throws {
      let h = try Harness()
      let first = "\u{e9}"
      let second = "e\u{301}"
      let firstID = CallID(rawValue: first)
      let secondID = CallID(rawValue: second)
      let firstAlias = try #require(RemoteCallID(rawValue: first))
      let secondAlias = try #require(RemoteCallID(rawValue: second))
      try await h.ring(IncomingCall(id: firstID, parties: [alice]), eventID: e1)
      try await h.ring(IncomingCall(id: secondID, parties: [alice]), eventID: e2)
      try await h.client.bindRemote(firstAlias, to: firstID)
      try await h.client.bindRemote(secondAlias, to: secondID)

      await h.client.receive(
        .endedRemotely, forRemote: firstAlias, eventID: EventID(rawValue: first))
      await h.client.receive(
        .endedRemotely, forRemote: secondAlias, eventID: EventID(rawValue: second))
      #expect(
        try await h.next(2) == [.ended(firstID, .endedRemotely), .ended(secondID, .endedRemotely)])
    }
  }
}
