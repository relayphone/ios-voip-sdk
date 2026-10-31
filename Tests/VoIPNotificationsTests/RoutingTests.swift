import Foundation
import Testing
import VoIPCore

@testable import VoIPNotifications

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct RoutingTests {
  let bob: Party = {
    do {
      return try Party(handles: [
        Handle(kind: .generic, value: "bob"), Handle(kind: .phoneNumber, value: "+442071838750"),
      ])
    } catch {
      preconditionFailure("The fixture handles are valid: \(error)")
    }
  }()

  // MARK: Responses to notifications

  @Test(arguments: [CallNotificationResponse.Action.open, .join])
  func responseForAPreviewJoinsIt(_ action: CallNotificationResponse.Action) async throws {
    let h = Harness()
    h.client.calls = [call(.previewing(dnd))]
    let response = CallNotificationResponse(callID: callID, caller: alice, action: action)
    #expect(try await h.notifier.handle(response) == .joining(callID))
    #expect(h.client.requests == [.join(callID)])
  }

  @Test func tapJoinsOnlyWhenJoinsOnTapIsOn() async throws {
    let h = Harness(options: CallNotifier.Options(joinsOnTap: false))
    h.client.calls = [call(.previewing(dnd))]
    let tap = CallNotificationResponse(callID: callID, caller: alice, action: .open)
    #expect(try await h.notifier.handle(tap) == nil)
    #expect(h.client.requests.isEmpty)
    let join = CallNotificationResponse(callID: callID, caller: alice, action: .join)
    #expect(try await h.notifier.handle(join) == .joining(callID))
  }

  @Test(arguments: [CallStatus.connecting, .connected])
  func responseForACallThatTakesPartHereDoesNothing(_ status: CallStatus) async throws {
    let h = Harness()
    h.client.calls = [call(status)]
    let response = CallNotificationResponse(callID: callID, caller: alice, action: .join)
    #expect(try await h.notifier.handle(response) == nil)
    #expect(h.client.requests.isEmpty)
  }

  @Test func responsePassesOnARefusedJoin() async throws {
    let h = Harness()
    h.client.calls = [call(.previewing(dnd))]
    h.client.error = .notAllowed(.ended(.endedRemotely))
    let response = CallNotificationResponse(callID: callID, caller: alice, action: .join)
    await #expect(throws: ActionError.notAllowed(.ended(.endedRemotely))) {
      try await h.notifier.handle(response)
    }
  }

  @Test(arguments: [CallNotificationResponse.Action.open, .join])
  func responseForACallThatIsOverCallsBack(_ action: CallNotificationResponse.Action)
    async throws
  {
    let h = Harness()
    h.client.calls = [call(.previewing(dnd), id: otherCallID)]
    let response = CallNotificationResponse(
      callID: callID, caller: alice, hasVideo: true, action: action)
    #expect(try await h.notifier.handle(response) == .callBack(alice, hasVideo: true))
    #expect(h.client.requests.isEmpty)
  }

  @Test func responseBeforeTheNotifierIsAttachedCallsBack() async throws {
    let notifier = CallNotifier(center: FakeCenterForRouting())
    let response = CallNotificationResponse(callID: callID, caller: alice, action: .join)
    #expect(try await notifier.handle(response) == .callBack(alice, hasVideo: false))
  }

  // MARK: Requests to call a party

  @Test func requestForAPartyWithALivePreviewJoinsTheNewest() async throws {
    let h = Harness()
    let older = Call(
      id: callID, isIncoming: true, parties: [bob], status: .previewing(.policy))
    let ringing = Call(
      id: CallID(rawValue: "ringing"), isIncoming: true, parties: [bob], status: .ringing)
    let newer = Call(
      id: otherCallID, isIncoming: true, parties: [alice, bob], status: .previewing(dnd))
    h.client.calls = [older, newer, ringing]
    let phoneOnly = try Party(handle: Handle(kind: .phoneNumber, value: "+442071838750"))
    #expect(
      try await h.notifier.handle(StartCallRequest(party: phoneOnly)) == .joining(otherCallID))
    #expect(h.client.requests == [.join(otherCallID)])
  }

  @Test func requestForAnotherPartyCallsIt() async throws {
    let h = Harness()
    h.client.calls = [
      call(.previewing(dnd)),
      Call(
        id: otherCallID, isIncoming: true, parties: [bob], status: .connected),
    ]
    let request = StartCallRequest(party: bob, hasVideo: true)
    #expect(try await h.notifier.handle(request) == .callBack(bob, hasVideo: true))
    #expect(h.client.requests.isEmpty)
  }

  @Test func requestPassesOnARefusedJoin() async throws {
    let h = Harness()
    h.client.calls = [call(.previewing(dnd))]
    h.client.error = .unknownCall
    await #expect(throws: ActionError.unknownCall) {
      try await h.notifier.handle(StartCallRequest(party: alice))
    }
  }

  // MARK: The notification's payload

  @Test func payloadRoundTripsThroughUserInfo() throws {
    let caller = try Party(
      handles: [
        Handle(kind: .phoneNumber, value: "+14155550123"),
        Handle(kind: .emailAddress, value: "alice@example.com"),
        Handle(kind: .generic, value: "a1"),
      ], displayName: "Alice")
    let notification = CallNotification(
      callID: callID, kind: .missed, caller: caller, hasVideo: true)
    var userInfo: [AnyHashable: Any] = ["aps": ["alert": "x"], "app": 1]
    userInfo.merge(CallNotificationPayload(notification).userInfo) { _, payload in payload }
    let payload = try #require(CallNotificationPayload(userInfo: userInfo))
    #expect(payload == CallNotificationPayload(callID: callID, caller: caller, hasVideo: true))
    let unnamed = CallNotificationPayload(callID: callID, caller: bob, hasVideo: false)
    #expect(CallNotificationPayload(userInfo: unnamed.userInfo) == unnamed)

    let response = CallNotificationResponse(userInfo: userInfo, action: .join)
    #expect(
      response
        == CallNotificationResponse(callID: callID, caller: caller, hasVideo: true, action: .join))
  }

  @Test func otherNotificationsHaveNoPayload() {
    let unreadable: [[AnyHashable: Any]] = [
      [:],
      ["callNotification": "call-1"],
      ["callNotification": ["callID": "call-1", "handles": [[String: String]]()]],
      ["callNotification": ["callID": "call-1", "handles": [["kind": "pager", "value": "1"]]]],
      [
        "callNotification": [
          "callID": "call-1", "handles": [["kind": "phoneNumber", "value": "1"]],
        ]
      ],
      ["callNotification": ["handles": [["kind": "generic", "value": "1"]]]],
    ]
    for userInfo in unreadable {
      #expect(CallNotificationPayload(userInfo: userInfo) == nil)
      #expect(CallNotificationResponse(userInfo: userInfo, action: .open) == nil)
    }
  }
}

/// A center for a notifier that only routes.
struct FakeCenterForRouting: CallNotificationCenter {
  func post(_ notification: CallNotification) async throws(CallNotificationError) {}
  func withdraw(_ id: CallID) async {}
}
