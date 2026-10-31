import Testing
import VoIPCore
import VoIPNotifications
import VoIPTesting

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct FakeCallNotificationCenterTests {
  @Test func keepsOneNotificationPerCall() async throws {
    let center = FakeCallNotificationCenter()
    try await center.post(notification(.incoming))
    try await center.post(notification(.incoming, otherCallID))
    try await center.post(notification(.missed))
    #expect(center.delivered == [notification(.missed), notification(.incoming, otherCallID)])

    await center.withdraw(callID)
    await center.withdraw(callID)
    #expect(center.delivered == [notification(.incoming, otherCallID)])
    #expect(
      center.records == [
        .post(notification(.incoming)), .post(notification(.incoming, otherCallID)),
        .post(notification(.missed)), .withdraw(callID), .withdraw(callID),
      ])
  }

  @Test func refusesPostsWithTheErrorItIsGiven() async throws {
    let center = FakeCallNotificationCenter()
    center.postError = .intentRejected
    await #expect(throws: CallNotificationError.intentRejected) {
      try await center.post(notification(.incoming))
    }
    #expect(center.records == [.post(notification(.incoming))])
    #expect(center.delivered.isEmpty)
  }
}

@Suite struct CallNotificationTests {
  @Test func defaultsToTheEnglishBodyForItsKind() {
    #expect(notification(.incoming).body == "Incoming call")
    #expect(notification(.incoming, hasVideo: true).body == "Incoming video call")
    #expect(notification(.missed).body == "Missed call")
    #expect(notification(.missed, hasVideo: true).body == "Missed video call")
    let given = CallNotification(callID: callID, kind: .missed, caller: alice, body: "Raté")
    #expect(given.body == "Raté")
  }
}
