#if os(iOS)
  import Intents
  import Testing
  import UserNotifications
  import VoIPCore

  @testable import VoIPNotifications

  /// The adapter's content, intent and person. Posting needs a signed app with the Communication
  /// Notifications capability, which the example app has.
  @Suite struct UserNotificationsAdapterTests {
    @Test func incomingCallContentBeforeTheIntentUpdatesIt() throws {
      let base = UNMutableNotificationContent()
      base.userInfo = ["app": "kept"]
      base.subtitle = "Work line"
      let content = UserNotificationsAdapter.baseContent(
        for: notification(.incoming, hasVideo: true), updating: base)
      #expect(content.title == "Alice")
      #expect(content.subtitle == "Work line")
      #expect(content.body == "Incoming video call")
      #expect(content.sound != nil)
      #expect(content.interruptionLevel == .active)
      #expect(content.threadIdentifier == "+14155550123")
      #expect(content.categoryIdentifier == UserNotificationsAdapter.categoryIdentifier)
      #expect(content.userInfo["app"] as? String == "kept")
      let payload = try #require(CallNotificationPayload(userInfo: content.userInfo))
      #expect(payload == CallNotificationPayload(callID: callID, caller: alice, hasVideo: true))
    }

    @Test func missedCallContentIsQuietWhenAsked() throws {
      var missed = notification(.missed)
      missed.interruptionLevel = .passive
      missed.playsSound = false
      missed.caller = try Party(handle: Handle(kind: .generic, value: "user-42"))
      let content = UserNotificationsAdapter.baseContent(
        for: missed, updating: UNNotificationContent())
      #expect(content.title == "user-42")
      #expect(content.body == "Missed call")
      #expect(content.sound == nil)
      #expect(content.interruptionLevel == .passive)
      #expect(content.categoryIdentifier.isEmpty)
    }

    @Test func categoryHasAJoinActionThatOpensTheApp() throws {
      let category = UserNotificationsAdapter.category(joinTitle: "Rejoindre")
      #expect(category.identifier == UserNotificationsAdapter.categoryIdentifier)
      let join = try #require(category.actions.first)
      #expect(category.actions.count == 1)
      #expect(join.identifier == UserNotificationsAdapter.joinActionIdentifier)
      #expect(join.title == "Rejoindre")
      #expect(join.options.contains(.foreground))
    }

    @Test(arguments: [false, true])
    func intentHasTheCallerAsItsOnlyContact(hasVideo: Bool) throws {
      let intent = INStartCallIntent(notification(.incoming, hasVideo: hasVideo))
      #expect(intent.destinationType == .normal)
      #expect(intent.callCapability == (hasVideo ? .videoCall : .audioCall))
      let person = try #require(intent.contacts?.first)
      #expect(intent.contacts?.count == 1)
      #expect(person.personHandle?.value == "+14155550123")
      #expect(person.personHandle?.type == .phoneNumber)
      #expect(person.displayName == "Alice")
      #expect(person.customIdentifier == "+14155550123")
      #expect(person.contactIdentifier == nil)
      #expect(person.image == nil)
      #expect(person.aliases == nil)
    }

    @Test func personKeepsEveryHandle() throws {
      let party = try Party(handles: [
        Handle(kind: .generic, value: "user-42"),
        Handle(kind: .emailAddress, value: "alice@example.com"),
        Handle(kind: .phoneNumber, value: "+14155550123"),
      ])
      let person = INPerson(party)
      #expect(person.personHandle?.type == .unknown)
      #expect(person.personHandle?.value == "user-42")
      #expect(person.customIdentifier == "user-42")
      #expect(person.aliases?.map(\.type) == [.emailAddress, .phoneNumber])
      #expect(Party(person: person) == party)
    }

    @Test func requestReadsTheIntentsFirstContact() throws {
      let siri = INPerson(
        personHandle: INPersonHandle(value: "(415) 555-0123", type: .phoneNumber),
        nameComponents: nil, displayName: "Alice", image: nil, contactIdentifier: "C1",
        customIdentifier: nil)
      let intent = INStartCallIntent(
        callRecordFilter: nil, callRecordToCallBack: nil, audioRoute: .unknown,
        destinationType: .normal, contacts: [siri, INPerson(alice)], callCapability: .videoCall)
      let request = try #require(StartCallRequest(intent))
      // The SDK doesn't reformat numbers, so one outside E.164 is kept as a generic handle.
      let expected = try Party(
        handle: Handle(kind: .generic, value: "(415) 555-0123"), displayName: "Alice")
      #expect(request == StartCallRequest(party: expected, hasVideo: true))

      let noContacts = INStartCallIntent(
        callRecordFilter: nil, callRecordToCallBack: nil, audioRoute: .unknown,
        destinationType: .normal, contacts: nil, callCapability: .audioCall)
      #expect(StartCallRequest(noContacts) == nil)
    }

    @Test func partyWithoutANameKeepsNone() throws {
      let unnamed = try Party(handle: Handle(kind: .phoneNumber, value: "+14155550123"))
      // The person reports the number, formatted, as its display name.
      #expect(Party(person: INPerson(unnamed)) == unnamed)
      let generic = try Party(handle: Handle(kind: .generic, value: "user-42"))
      #expect(Party(person: INPerson(generic)) == generic)
      let numbered = try Party(
        handle: Handle(kind: .phoneNumber, value: "+14155550123"), displayName: "4155550123 Ltd")
      #expect(Party(person: INPerson(numbered)) == numbered)
    }
  }
#endif
