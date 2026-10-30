import Foundation
import Testing

@testable import VoIPSDK

struct ParticipantTests {
  @Test func avatarURLPreservesTheLegacyStringKey() throws {
    let avatar = try #require(URL(string: "https://example.com/avatar.png"))
    let participant = Participant(
      id: "caller", displayName: "Caller", avatarURL: avatar,
      phoneNumber: "+15555550142", email: "caller@example.com")
    let data = try JSONEncoder().encode(participant)
    #expect(
      try JSONDecoder().decode(JSONValue.self, from: data)
        == .object([
          "id": .string("caller"), "displayName": .string("Caller"),
          "avatarUrl": .string("https://example.com/avatar.png"),
          "phoneNumber": .string("+15555550142"), "email": .string("caller@example.com"),
        ]))
    let decoded = try JSONDecoder().decode(Participant.self, from: data)
    #expect(decoded == participant)
    #expect(decoded.avatarURL == avatar)
  }

  @Test(arguments: [#"{"id":"caller"}"#, #"{"id":"caller","avatarUrl":null}"#])
  func absentAvatarRemainsOptional(body: String) throws {
    let participant = try JSONDecoder().decode(Participant.self, from: Data(body.utf8))
    #expect(participant.avatarURL == nil)
    #expect(
      try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(participant))
        == .object([
          "id": .string("caller")
        ]))
  }

  @Test(arguments: [JSONValue.string("http://["), .int(42)])
  func invalidAvatarCannotDecodeAsAURL(value: JSONValue) throws {
    let data = try JSONEncoder().encode(
      JSONValue.object([
        "id": .string("caller"), "avatarUrl": value,
      ]))
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(Participant.self, from: data)
    }
  }
}
