import Testing
import VoIPCore

@testable import VoIPAudio

/// How the adapter reads interruptions and media services resets in the shape each system posts
/// them.
@Suite("Interruptions")
@VoIPActor
struct InterruptionTests {
  /// The notifications a system posts for one interruption, and the events the SDK hears.
  struct Shape: Sendable, CustomTestStringConvertible {
    let name: String
    let notifications: [SessionNotification]
    let events: [AudioSessionEvent]

    var testDescription: String { name }
  }

  nonisolated static let shapes: [Shape] = [
    Shape(
      name: "iOS 26: began with a reason, then ended",
      notifications: [.interruptionBegan(.builtInMicMuted), .interruptionEnded],
      events: [.interruptionBegan(.builtInMicMuted), .interruptionEnded]),
    Shape(
      name: "iOS 26: began without a reason",
      notifications: [.interruptionBegan(nil), .interruptionEnded],
      events: [.interruptionBegan(.otherAudio), .interruptionEnded]),
    Shape(
      name: "iOS 27: became inactive for an interruption, then a resumption recommendation",
      notifications: [.becameInactive(interruption: .routeDisconnected), .resumptionRecommended],
      events: [.interruptionBegan(.routeDisconnected), .interruptionEnded]),
    Shape(
      name: "iOS 27: another app's audio",
      notifications: [.becameInactive(interruption: .otherAudio), .resumptionRecommended],
      events: [.interruptionBegan(.otherAudio), .interruptionEnded]),
    Shape(
      name: "iOS 27: the system deactivated the session without an interruption",
      notifications: [.becameInactive(interruption: nil)],
      events: []),
  ]

  @Test(arguments: shapes)
  func eachSystemsInterruptionReachesTheSDKTheSameWay(_ shape: Shape) {
    let attached = Attached()
    for notification in shape.notifications { attached.notifications.post(notification) }
    #expect(attached.events == shape.events)
    #expect(attached.session.records.isEmpty, "An interruption never changes the session")
  }

  @Test func mediaServicesResetReachesTheSDKAndRereadsTheRoutes() {
    let attached = Attached()
    attached.session.current = SessionPorts(
      inputs: [.builtInMic, .airPodsHFP], outputs: [.airPodsHFP])
    attached.notifications.post(.mediaServicesWereReset)
    #expect(attached.events == [.mediaServicesReset])
    #expect(attached.adapter.list.current?.name == "AirPods Pro")
    // The SDK configures the session again, for the calls that take part.
    #expect(attached.session.records.isEmpty)
  }

  @Test func routeChangesAreNotEvents() {
    let attached = Attached()
    attached.notifications.post(.routesChanged)
    #expect(attached.events.isEmpty)
  }
}
