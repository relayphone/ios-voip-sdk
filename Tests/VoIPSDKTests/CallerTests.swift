import Foundation
import Testing

@testable import VoIPSDK

struct CallerTests {
  @Test func normalizesPhoneAndRoundTrips() throws {
    let phone = try Caller(
      handleType: .phone, value: "+1 (202) 555-0123",
      displayName: " Cafe caller ", hostContactID: "host-42")
    #expect(phone.value == "+12025550123")
    #expect(phone.displayName == "Cafe caller")
    #expect(phone.hostContactID == "host-42")
    #expect(try JSONDecoder().decode(Caller.self, from: JSONEncoder().encode(phone)) == phone)
  }

  @Test(arguments: [
    "2025550123", "+0123", "+1234567890123456", "+1-202-555-0123x5", "+١٢٠٢٥٥٥٠١٢٣", "+",
  ])
  func rejectsInvalidPhone(value: String) {
    #expect(throws: Caller.ValidationError.invalidValue) {
      try Caller(handleType: .phone, value: value, displayName: "Caller")
    }
  }

  @Test(arguments: [
    #"{"handleType":"unknown","value":"id","displayName":"Name"}"#,
    #"{"handleType":"phone","value":"2025550123","displayName":"Name"}"#,
    #"{"handleType":"generic","value":"id","displayName":" "}"#,
    #"{"handleType":"generic","value":"id","displayName":"Name","hostContactID":" "}"#,
  ])
  func validatesDecodedCaller(json: String) {
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(Caller.self, from: Data(json.utf8))
    }
  }

  @Test(arguments: ["", " ", "a\nb", "a\u{0}b"])
  func rejectsInvalidGeneric(value: String) {
    #expect(throws: Caller.ValidationError.invalidValue) {
      try Caller(handleType: .generic, value: value, displayName: "Caller")
    }
  }

  @Test func trimsEmail() throws {
    let email = try Caller(handleType: .email, value: " Alice@example.com ", displayName: "Alice")
    #expect(email.value == "Alice@example.com")
    #expect(
      email.participant
        == Participant(id: "Alice@example.com", displayName: "Alice", email: "Alice@example.com"))
  }

  @Test(arguments: ["no-at", "@example.com", "a@", "a@@example.com", "a b@example.com"])
  func rejectsInvalidEmail(value: String) {
    #expect(throws: Caller.ValidationError.invalidValue) {
      try Caller(handleType: .email, value: value, displayName: "Caller")
    }
  }

  @Test func projectsTypedParticipants() throws {
    let generic = try Caller(handleType: .generic, value: "opaque-caller", displayName: "Opaque")
    let phone = try Caller(handleType: .phone, value: "+12025550123", displayName: "Cafe caller")
    #expect(generic.participant == Participant(id: "opaque-caller", displayName: "Opaque"))
    #expect(
      phone.participant
        == Participant(id: "+12025550123", displayName: "Cafe caller", phoneNumber: "+12025550123"))
  }
}
