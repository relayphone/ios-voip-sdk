import Foundation

@main struct CallerTests {
  static func main() throws {
    let phone = try Caller(handleType: .phone, value: "+1 (202) 555-0123", displayName: " Cafe caller ", hostContactID: "host-42")
    precondition(phone.value == "+12025550123" && phone.displayName == "Cafe caller")
    precondition(phone.hostContactID == "host-42")
    let encoded = try JSONEncoder().encode(phone)
    let decoded = try JSONDecoder().decode(Caller.self, from: encoded)
    precondition(decoded == phone)
    for invalid in ["2025550123", "+0123", "+1234567890123456", "+1-202-555-0123x5", "+١٢٠٢٥٥٥٠١٢٣", "+"] {
      do { _ = try Caller(handleType: .phone, value: invalid, displayName: "Caller"); preconditionFailure("Invalid phone accepted") }
      catch Caller.ValidationError.invalidValue {}
    }
    for raw in [#"{"handleType":"unknown","value":"id","displayName":"Name"}"#,
                #"{"handleType":"phone","value":"2025550123","displayName":"Name"}"#,
                #"{"handleType":"generic","value":"id","displayName":" "}"#,
                #"{"handleType":"generic","value":"id","displayName":"Name","hostContactID":" "}"#] {
      do { _ = try JSONDecoder().decode(Caller.self, from: Data(raw.utf8)); preconditionFailure("Invalid Caller decoded") } catch {}
    }
    for value in ["", " ", "a\nb", "a\u{0}b"] {
      do { _ = try Caller(handleType: .generic, value: value, displayName: "Caller"); preconditionFailure("Invalid generic accepted") }
      catch Caller.ValidationError.invalidValue {}
    }
    let email = try Caller(handleType: .email, value: " Alice@example.com ", displayName: "Alice")
    precondition(email.value == "Alice@example.com")
    for value in ["no-at", "@example.com", "a@", "a@@example.com", "a b@example.com"] {
      do { _ = try Caller(handleType: .email, value: value, displayName: "Caller"); preconditionFailure("Invalid email accepted") }
      catch Caller.ValidationError.invalidValue {}
    }
    let generic = try Caller(handleType: .generic, value: "opaque-caller", displayName: "Opaque")
    precondition(generic.participant == Participant(id: "opaque-caller", displayName: "Opaque"))
    precondition(phone.participant == Participant(id: "host-42", displayName: "Cafe caller", phoneNumber: "+12025550123"))
    print("passed: Caller normalization, validation, Codable and participant projection")
  }
}
