import Testing
import VoIPCore
import VoIPTesting

@testable import VoIPConversationsMapping

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct MappingClientTests {}

extension MappingClientTests {
  @Suite
  @MainActor
  struct CallAudioConfigurationTests {
    @Test func holdAndResumeKeepTheCallConfiguration() async throws {
      let framework = FakeCallingFramework()
      let audio = FakeAudioSession()
      let session = ConfigurationSession()
      let media = ConfigurationMedia(session)
      let bridge = AudioSessionBridge(adapter: audio) { session.remember() }
      let client = try VoIPClient.start(framework: framework, media: media, audio: bridge)
      var events = client.events().makeAsyncIterator()
      let id = CallID(rawValue: "held")
      _ = await client.report(IncomingCall(id: id, parties: []))
      _ = await events.next()
      await framework.perform(.answer(id))
      _ = await events.next()
      await framework.send(.audioActivated)
      _ = await events.next()
      await framework.perform(.hold(id, onHold: true))
      _ = await events.next()
      await framework.send(.audioDeactivated)
      _ = await events.next()
      #expect(await session.value == .call)
      await framework.perform(.hold(id, onHold: false))
      _ = await events.next()
      await framework.send(.audioActivated)
      _ = await events.next()
      #expect(await session.value == .call)
      #expect(await audio.configuredCalls.map(\.id) == [id])
      await framework.perform(.end(id))
      _ = await events.next()
      await framework.send(.audioDeactivated)
      _ = await events.next()
      #expect(await session.value == .app)
    }

  }
}

@VoIPActor
private final class ConfigurationSession {
  enum Value: Sendable { case app, call }
  var value = Value.app
  lazy var configuration = CallAudioConfiguration<Value> { [weak self] in self?.value = $0 }
  nonisolated init() {}
  func remember() { configuration.remember(value) }
}

@VoIPActor
private final class ConfigurationMedia: CallMedia {
  let session: ConfigurationSession
  nonisolated init(_ session: ConfigurationSession) { self.session = session }
  func prepare(_ call: Call) async throws { session.value = .call }
  func activate() {}
  func deactivate() { session.configuration.deactivate() }
}
