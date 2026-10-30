import Testing
import VoIPCore

@Suite struct HandleTests {
  @Test(arguments: ["+14155550123", "+442071838750", "+12", "+123456789012345"])
  func acceptsE164PhoneNumbers(_ value: String) throws {
    let handle = try Handle(kind: .phoneNumber, value: value)
    #expect(handle.kind == .phoneNumber)
    #expect(handle.value == value)
  }

  @Test(arguments: [
    "14155550123", "+04155550123", "+1", "+1234567890123456", "+1 415 555 0123",
    "+1-415-555-0123", "+1415555012a", "++14155550123", "+١٤١٥٥٥٥٠١٢٣", " +14155550123",
  ])
  func rejectsPhoneNumbersOutsideE164(_ value: String) {
    #expect(throws: HandleError.invalidPhoneNumber) {
      try Handle(kind: .phoneNumber, value: value)
    }
  }

  @Test(arguments: Handle.Kind.allCases, ["", " ", "\n\t"])
  func rejectsEmptyValues(_ kind: Handle.Kind, _ value: String) {
    #expect(throws: HandleError.empty) { try Handle(kind: kind, value: value) }
  }

  @Test(arguments: [
    (Handle.Kind.emailAddress, "alice@example.com"), (.generic, "user-42"), (.generic, "Alice B"),
  ])
  func keepsOtherValuesAsGiven(_ kind: Handle.Kind, _ value: String) throws {
    let handle = try Handle(kind: kind, value: value)
    #expect(handle.value == value)
  }
}

@Suite struct PartyTests {
  @Test func presentsTheFirstHandle() throws {
    let email = try Handle(kind: .emailAddress, value: "alice@example.com")
    let phone = try Handle(kind: .phoneNumber, value: "+14155550123")
    let party = try Party(handles: [email, phone], displayName: "Alice")
    #expect(party.presentedHandle == email)
    #expect(party.handles == [email, phone])
    #expect(party.displayName == "Alice")
    #expect(Party(handle: phone).handles == [phone])
  }

  @Test func needsAHandle() {
    #expect(throws: PartyError.noHandles) { try Party(handles: []) }
  }
}

@Suite struct ConfigurationTests {
  @Test func defaultsMatchTheDocumentedPolicy() {
    let configuration = VoIPConfiguration()
    #expect(configuration.capabilities == [.holding, .playingTones])
    #expect(configuration.presentationPolicy.incoming == .ring)
    #expect(configuration.presentationPolicy.previewsFilteredCalls)
    #expect(configuration.presentationPolicy.previewsCallsAnsweredElsewhere)
    #expect(
      configuration.deadlines
        == Deadlines(
          ring: .seconds(60), placement: .seconds(10), mediaPreparation: .seconds(2),
          audioActivation: .seconds(10), connect: .seconds(30), reconnect: .seconds(65)))
  }

  @Test func everyActionNamesItsCall() {
    let id = CallID(rawValue: "call-1")
    let actions: [Action] = [
      .start(OutgoingCall(id: id, parties: [])), .answer(id), .join(id), .end(id),
      .hold(id, onHold: true), .mute(id, muted: true), .playTones(id, digits: "1"),
      .merge(id, with: CallID(rawValue: "call-2")), .unmerge(id),
    ]
    #expect(actions.allSatisfy { $0.callID == id })
  }
}
