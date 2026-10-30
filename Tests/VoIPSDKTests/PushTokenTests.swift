import Foundation
import Testing

@testable import VoIPSDK

@MainActor
struct PushTokenTests {
  @Test func tokenUpdatesDeduplicateAndInvalidate() throws {
    let tokens = PushTokenStore()
    #expect(tokens.state.revision == 0 && tokens.state.token == nil)
    tokens.update(Data([1, 2, 255]))
    #expect(tokens.state.revision == 1 && tokens.state.token?.value == "0102ff")
    tokens.update(Data([1, 2, 255]))
    #expect(tokens.state.revision == 1)
    tokens.update(nil)
    #expect(tokens.state.revision == 2 && tokens.state.token == nil)
    let json = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(tokens.state)) as? [String: Any])
    #expect(json["token"] is NSNull)
    tokens.update(Data())
    #expect(tokens.state.revision == 2)
  }

  @Test func observersHydrateReentrantlyAndUnsubscribe() {
    let tokens = PushTokenStore()
    var notifications: [PushTokenState] = []
    let subscription = tokens.observe { state in
      notifications.append(state)
      if state.token?.value == "aa" { tokens.update(Data([0xbb])) }
    }
    tokens.update(Data([0xaa]))
    #expect(notifications.map(\.revision) == [0, 1, 2])
    #expect(notifications.last?.token?.value == "bb")
    tokens.removeObserver(subscription)
    tokens.update(nil)
    #expect(notifications.count == 3)
    var hydrated: PushTokenState?
    let hydrateSubscription = tokens.observe { hydrated = $0 }
    #expect(hydrated?.revision == 3 && hydrated?.token == nil)
    tokens.removeObserver(hydrateSubscription)
  }

  @Test func simulatorActivationLocksLaunchPreference() throws {
    try SimulatorSupport.configure(enabled: false)
    #expect(!SimulatorSupport.activateIfNeeded())
    #expect(throws: SimulatorSupport.ConfigurationError.activationAlreadyRequested) {
      try SimulatorSupport.configure(enabled: true)
    }
    try SimulatorSupport.configure(enabled: false)
  }
}
