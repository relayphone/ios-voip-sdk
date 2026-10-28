import Foundation
import Intents

@main struct IntentTests {
  @MainActor static func main() throws {
    for (type, value, expected) in [(Caller.HandleType.phone, "+1 (202) 555-0123", INPersonHandleType.phoneNumber),
      (.email, "Alice@example.com", .emailAddress), (.generic, "host-handle", .unknown)] {
      let caller = try Caller(handleType: type, value: value, displayName: "Exact person", hostContactID: "host-person-42")
      let interaction = caller.makeCallInteraction(video: true)
      guard let intent = interaction.intent as? INStartCallIntent,
            let person = intent.contacts?.first else { preconditionFailure("Missing typed call intent") }
      precondition(intent.contacts?.count == 1 && intent.callCapability == .videoCall)
      precondition(person.personHandle?.type == expected && person.personHandle?.value == caller.value)
      precondition(person.displayName == "Exact person" && person.customIdentifier == "host-person-42")
      precondition(person.contactIdentifier == nil && interaction.direction == .incoming)
      let outgoing = caller.makeCallInteraction(direction: .outgoing)
      precondition(outgoing.direction == .outgoing)
      precondition((outgoing.intent as? INStartCallIntent)?.callCapability == .audioCall)
    }
    print("passed: actual INPerson/INStartCallIntent exact identity, video, direction and opaque host contact ID; no donation performed")
  }
}
