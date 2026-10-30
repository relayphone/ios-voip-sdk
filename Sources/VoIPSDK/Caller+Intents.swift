#if canImport(Intents)
import Foundation
@preconcurrency public import Intents

extension Caller {
  /// The same typed identity used in the LCK report, for host-driven call donation.
  /// hostContactID stays an app identifier; it never impersonates an Apple contact.
  @MainActor public func makeCallInteraction(video: Bool = false,
                                             direction: ConversationDirection = .incoming) -> INInteraction {
    let type: INPersonHandleType
    switch handleType {
    case .phone: type = .phoneNumber
    case .email: type = .emailAddress
    case .generic: type = .unknown
    }
    let person = INPerson(personHandle: INPersonHandle(value: value, type: type),
      nameComponents: nil, displayName: displayName, image: nil,
      contactIdentifier: nil, customIdentifier: hostContactID)
    let intent = INStartCallIntent(callRecordFilter: nil, callRecordToCallBack: nil,
      audioRoute: .unknown, destinationType: .normal, contacts: [person],
      callCapability: video ? .videoCall : .audioCall)
    let interaction = INInteraction(intent: intent, response: nil)
    interaction.direction = direction == .incoming ? .incoming : .outgoing
    return interaction
  }

  /// Call after a real call interaction. No donation occurs while parsing a push.
  @MainActor public func donateCall(video: Bool = false,
                                    direction: ConversationDirection = .incoming) async throws {
    try await makeCallInteraction(video: video, direction: direction).donate()
  }
}
#endif
