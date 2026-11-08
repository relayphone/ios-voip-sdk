import Testing
import VoIPCore

@testable import VoIPConversationsMapping

@Suite("Native bridge ordering")
struct BridgeTests {
  @Test
  func placementKeepsTheOriginUntilTheActionIsPerformed() {
    let id = CallID(rawValue: "app-id")
    let start = Action.start(OutgoingCall(id: id, parties: []))
    var origins = ActionOrigins()
    #expect(origins.placement(for: id) == .system)
    for action in [start, .join(id)] {
      origins.append(action)
      #expect(origins.placement(for: id) == .app)
      #expect(origins.placement(for: id) == .app)
      #expect(origins.take(action) == .app)
      #expect(origins.take(action) == .system)
    }
    origins.append(.join(id))
    origins.append(.end(id))
    origins.cancelPlacement(for: id)
    #expect(origins.placement(for: id) == .system)
    #expect(origins.take(.end(id)) == .app)
    origins.append(start)
    origins.withdraw(start)
    #expect(origins.take(start) == .system)
    origins.append(.mute(id, muted: true))
    origins.ended(id)
    #expect(origins.take(.mute(id, muted: true)) == .system)
  }

  @Test @VoIPActor
  func mediaCapturesTheSessionBeforeTheSDKChangesIt() throws {
    let adapter = FakeAudio()
    let bridge = AudioSessionBridge(adapter: adapter) { adapter.earlier = adapter.category }
    bridge.attach { adapter.events.append($0) }
    try bridge.configure(
      for: Call(
        id: CallID(rawValue: "call"), isIncoming: true, parties: [], status: .connecting))
    #expect(adapter.earlier == .app)
    #expect(adapter.category == .call)
    adapter.onEvent?(.mediaServicesReset)
    #expect(adapter.events == [.mediaServicesReset])
    adapter.refusesConfiguration = true
    #expect(throws: AudioSessionError.configurationFailed) {
      try bridge.configure(
        for: Call(
          id: CallID(rawValue: "other"), isIncoming: true, parties: [], status: .connecting))
    }
  }
}

@VoIPActor
private final class FakeAudio: AudioSession {
  enum Category { case app, call }
  var category = Category.app
  var earlier: Category?
  var events: [AudioSessionEvent] = []
  var refusesConfiguration = false
  var onEvent: (@VoIPActor (AudioSessionEvent) -> Void)?

  func attach(onEvent: @escaping @VoIPActor (AudioSessionEvent) -> Void) {
    self.onEvent = onEvent
  }

  func configure(for call: Call) throws(AudioSessionError) {
    if refusesConfiguration { throw .configurationFailed }
    category = .call
  }
}
