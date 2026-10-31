#if os(iOS) && targetEnvironment(simulator)
  import CKSimProtocol
  import Foundation
  import Testing
  import VoIPCore
  import VoIPNotifications
  import VoIPTesting

  extension Journeys {
    /// Do Not Disturb filters a pushed call, which becomes a call preview with a call
    /// notification. The call ends without being joined here, and its notification becomes a
    /// missed-call notification.
    @Test func filteredCallPostsANotificationThenAMissedCallOne() async throws {
      let center = FakeCallNotificationCenter()
      let app = try await App(observers: [CallNotifier(center: center)])
      defer { app.stop() }
      try await app.system.filterIncomingCalls(.doNotDisturb)
      let id = newCallID("notified")
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
      let caller = try Party(
        handle: Handle(kind: .phoneNumber, value: "+14155550123"), displayName: "Alice")
      let incoming = CallNotification(callID: id, kind: .incoming, caller: caller)
      try await app.until("the call's notification") { center.delivered == [incoming] }

      // The call goes on elsewhere, such as with an assistant, and ends there.
      await app.client.receive(.endedRemotely, for: id, eventID: EventID(rawValue: "end-\(id)"))
      try await app.expect([.ended(id, .endedRemotely)])
      let missed = CallNotification(callID: id, kind: .missed, caller: caller)
      try await app.until("the missed-call notification") { center.delivered == [missed] }
      #expect(center.records == [.post(incoming), .post(missed)])
      #expect(try await app.system.calls().isEmpty)
      #expect(await app.media.records.isEmpty)
      try await app.expectPushesFinished([pushID])
      app.expectNoMoreEvents()
    }
  }
#endif
