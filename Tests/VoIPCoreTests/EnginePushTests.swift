import Foundation
import Testing
import VoIPTesting

@testable import VoIPCore

extension EngineTests {
  /// VoIP push intake: reporting before the push callback returns, and deduplication.
  @Suite("Push intake")
  @MainActor
  struct PushIntake {
    @Test func reportsBeforeTheCallbackReturnsAndFinishesAfterTheOutcome() async throws {
      let h = try Harness()
      let framework = h.framework
      let push = h.push
      let delivery = VoIPPush.incoming(ringingCall, eventID: e1)
      await onVoIPActor { framework.presentationOutcome = nil }

      let (records, finished) = await onVoIPActor {
        push.deliver(delivery)
        return (framework.records, push.finished)
      }
      #expect(Reported.classify(records) == [.report(callID)])
      #expect(finished.isEmpty)

      await onVoIPActor { framework.completeReports(of: callID, with: .presented) }
      #expect(await push.finished == [delivery])
      #expect(try await h.next() == .presented(callID))
    }

    /// One row of the push table: what this device already has, the push, and what the SDK
    /// reports and tells the app.
    enum Row: String, CaseIterable, Sendable, CustomTestStringConvertible {
      case newCall
      case repeatedEventID
      case repeatedCallID
      case callInPreview
      case endedCall
      case endedCallAfterRetention
      case beyondCapacity
      case unrecognized
      case previewPolicy
      case nonePolicy
      case serverEventForRingingCall
      case serverEventForUnknownCall
      case repeatedServerEvent

      var testDescription: String { rawValue }

      var configuration: VoIPConfiguration {
        self == .beyondCapacity ? VoIPConfiguration(maximumCalls: 1) : VoIPConfiguration()
      }

      /// Sets up what the device already has, returning the number of pushes delivered.
      func setUp(_ h: Harness) async -> Int {
        switch self {
        case .repeatedEventID, .repeatedCallID, .serverEventForRingingCall:
          await h.deliver(.incoming(ringingCall, eventID: e1))
          return 1
        case .callInPreview:
          _ = await h.client.report(incoming(callID, .preview))
          return 0
        case .endedCall, .endedCallAfterRetention:
          await h.deliver(.incoming(ringingCall, eventID: e1))
          await h.framework.perform(.end(callID))
          if self == .endedCallAfterRetention {
            h.clock.advance(by: configuration.retention)
          }
          return 1
        case .beyondCapacity:
          await h.deliver(.incoming(IncomingCall(id: otherCallID, parties: [alice]), eventID: e3))
          return 1
        case .repeatedServerEvent:
          await h.deliver(.incoming(ringingCall, eventID: e1))
          await h.client.receive(.partiesChanged([bob]), for: callID, eventID: e2)
          return 1
        case .newCall, .unrecognized, .previewPolicy, .nonePolicy, .serverEventForUnknownCall:
          return 0
        }
      }

      var push: VoIPPush {
        switch self {
        case .repeatedEventID: .incoming(ringingCall, eventID: e1)
        case .unrecognized: .unrecognized
        case .previewPolicy: .incoming(incoming(callID, .preview), eventID: e2)
        case .nonePolicy: .incoming(incoming(callID, .none), eventID: e2)
        case .serverEventForRingingCall, .serverEventForUnknownCall:
          .serverEvent(.answeredElsewhere, for: callID, eventID: e2)
        case .repeatedServerEvent: .serverEvent(.endedRemotely, for: callID, eventID: e2)
        default: .incoming(ringingCall, eventID: e2)
        }
      }

      func reported(mustReport: Bool) -> [Reported] {
        func throwaway(_ parties: [Party], _ reason: EndReason) -> [Reported] {
          mustReport ? [.throwaway(parties: parties), .throwawayEnded(reason)] : []
        }
        // A push for a call that the system presents is reported with a throwaway call too: the
        // system doesn't count a second report of a call it has.
        switch self {
        case .newCall, .endedCallAfterRetention:
          return [.report(callID)]
        case .repeatedEventID, .repeatedCallID, .callInPreview, .endedCall, .previewPolicy,
          .nonePolicy:
          return throwaway([alice], .failed(.server))
        case .repeatedServerEvent:
          // With the parties the call has when the push arrives.
          return throwaway([bob], .failed(.server))
        case .beyondCapacity:
          return throwaway([alice], .failed(.atCapacity))
        case .unrecognized, .serverEventForUnknownCall:
          return throwaway([], .failed(.server))
        case .serverEventForRingingCall:
          return throwaway([alice], .failed(.server)) + [.ended(callID, .answeredElsewhere)]
        }
      }

      var events: [Seen] {
        switch self {
        case .newCall, .endedCallAfterRetention: [.presented(callID)]
        case .beyondCapacity: [.ended(callID, .failed(.atCapacity))]
        case .previewPolicy: [.previewStarted(callID, .policy)]
        case .serverEventForRingingCall: [.previewStarted(callID, .answeredElsewhere)]
        default: []
        }
      }
    }

    @Test(arguments: Row.allCases, [true, false])
    func push(_ row: Row, mustReport: Bool) async throws {
      let h = try Harness(configuration: row.configuration, subscribe: false)
      let delivered = await row.setUp(h)
      let before = await h.records.count
      h.subscribe()

      await h.deliver(row.push, mustReport: mustReport)
      #expect(await h.reported(after: before) == row.reported(mustReport: mustReport))
      #expect(await h.push.finished.count == delivered + 1)
      for event in row.events {
        #expect(try await h.next() == event)
      }
      try await h.expectNoEvents()
    }

    @Test func pushMetadataReachesTheCall() async throws {
      let h = try Harness()
      let payload = #"""
        {"incomingCall":{"eventId":"event-1","serverCallId":"call-1",
        "caller":{"handleType":"phone","value":"+14155550123","displayName":"Alice"},
        "metadata":{"room":"room-1","route":{"region":"eu","hops":["sip",2,false,null]}}}}
        """#
      await h.deliver(VoIPPush(defaultFormat: Data(payload.utf8)))
      #expect(try await h.next() == .presented(callID))

      await h.until { !$0.calls.isEmpty }
      let expected: [String: JSONValue] = [
        "room": "room-1", "route": ["region": "eu", "hops": ["sip", 2, false, .null]],
      ]
      #expect(h.client.calls.map(\.metadata) == [expected])
    }

    @Test func repeatedPushWhileTheFirstReportWaits() async throws {
      let h = try Harness()
      let framework = h.framework
      await onVoIPActor { framework.presentationOutcome = nil }
      let first = VoIPPush.incoming(ringingCall, eventID: e1)
      let repeated = VoIPPush.incoming(ringingCall, eventID: e2)
      await h.deliver(first)
      await h.deliver(repeated)
      #expect(
        await h.reported() == [
          .report(callID), .throwaway(parties: [alice]), .throwawayEnded(.failed(.server)),
        ])
      #expect(await h.push.finished.isEmpty)

      // Each push finishes when the system answers its own report.
      await onVoIPActor { framework.completeReports(of: callID, with: .presented) }
      #expect(await h.push.finished == [first])
      #expect(try await h.next() == .presented(callID))
      let throwaway = try #require(await framework.waitingCalls.first)
      await onVoIPActor { framework.completeReports(of: throwaway.id, with: .presented) }
      #expect(await h.push.finished == [first, repeated])
      try await h.expectNoEvents()
    }

    @Test func serverEventBeforeItsCallAppliesWhenTheCallArrives() async throws {
      let h = try Harness()
      await h.client.receive(.answeredElsewhere, for: callID, eventID: e2)
      await h.deliver(.incoming(ringingCall, eventID: e1))
      #expect(await h.reported() == [.report(callID), .ended(callID, .answeredElsewhere)])
      #expect(try await h.next() == .previewStarted(callID, .answeredElsewhere))
    }

    @Test func serverEventBeforeItsCallIsForgottenAfterRetention() async throws {
      let h = try Harness()
      await h.client.receive(.endedRemotely, for: callID, eventID: e2)
      h.clock.advance(by: VoIPConfiguration().retention)
      try await h.ring()
      try await h.expectNoEvents()
    }

    /// A device joined a call preview, then received a VoIP push that the call ended. With the
    /// app in the background, the system requires a report for the push, and doesn't count a
    /// second report of the joined call.
    @Test(arguments: [true, false])
    func endedPushForAJoinedCall(mustReport: Bool) async throws {
      let h = try Harness()
      _ = await h.client.report(incoming(callID, .preview))
      #expect(try await h.next() == .previewStarted(callID, .policy))
      try await h.client.request(.join(callID))
      #expect(try await h.next() == .joinRequested(callID))
      await h.client.confirmPlaced(callID)
      #expect(try await h.next() == .performed(.join(callID), .connecting))
      await h.framework.send(.audioActivated)
      #expect(try await h.next() == .audioActivated)
      let before = await h.records.count

      let ended = VoIPPush.serverEvent(.endedRemotely, for: callID, eventID: e2)
      await h.deliver(ended, mustReport: mustReport)
      #expect(try await h.next() == .ended(callID, .endedRemotely))
      let throwaway: [Reported] =
        mustReport ? [.throwaway(parties: [alice]), .throwawayEnded(.failed(.server))] : []
      #expect(await h.reported(after: before) == throwaway + [.ended(callID, .endedRemotely)])
      #expect(await h.push.finished == [ended])
      try await h.expectNoEvents()
    }

    @Test func pushForAConnectedCallLeavesTheCallItsAudioAndItsMediaAlone() async throws {
      let h = try Harness()
      try await h.connect()
      await h.until { $0.calls.map(\.status) == [.connected] && $0.isAudioActive }
      let before = await h.records.count
      let media = await h.media.records

      await h.deliver(.serverEvent(.reconnecting, for: callID, eventID: e2))
      await h.until { $0.calls.map(\.status) == [.reconnecting] }
      #expect(
        await h.reported(after: before) == [
          .throwaway(parties: [alice]), .throwawayEnded(.failed(.server)),
        ])
      #expect(await h.push.finished.count == 2)
      #expect(await h.media.records == media)
      #expect(h.client.isAudioActive)

      // The SDK fails what the system asks of the throwaway call, such as an answer from a user
      // who tapped it before it ended.
      let records = await h.records
      let throwaway = try #require(
        records.dropFirst(before).lazy.compactMap { record -> CallID? in
          if case .reportIncoming(let call) = record { call.id } else { nil }
        }.first)
      let answer = await h.framework.perform(.answer(throwaway))
      #expect(await h.records.last == .fail(answer))
      try await h.expectNoEvents()
      #expect(h.client.calls.first { $0.id == callID }?.status == .reconnecting)
      #expect(await h.media.records == media)
    }

    @Test func repeatedServerEventIsIgnored() async throws {
      let h = try Harness()
      try await h.ring()
      await h.client.receive(.partiesChanged([bob]), for: callID, eventID: e2)
      await h.client.receive(.endedRemotely, for: callID, eventID: e2)
      try await h.expectNoEvents()
      #expect(await h.reported().count == 2)
      await h.until { $0.calls.first?.parties == [bob] }
    }
  }
}

@Suite struct DeviceUUIDTests {
  @Test func isDerivedFromTheCallID() {
    #expect(deviceUUID(for: callID) == UUID(uuidString: "5D7963C4-F471-8142-B5A7-2214A9666FB1"))
    #expect(
      deviceUUID(for: otherCallID) == UUID(uuidString: "3BA8DCED-2E72-8B16-9DFB-4E6A16F08D0F"))
    #expect(deviceUUID(for: CallID(rawValue: "call-1")) == deviceUUID(for: callID))
  }

  @Test(arguments: ["", "call-1", "a much longer call identifier with spaces and ünïcödé"])
  func isAVersion8UUID(_ id: String) {
    let uuid = deviceUUID(for: CallID(rawValue: id)).uuid
    #expect(uuid.6 >> 4 == 8)
    #expect(uuid.8 >> 6 == 0b10)
  }
}
