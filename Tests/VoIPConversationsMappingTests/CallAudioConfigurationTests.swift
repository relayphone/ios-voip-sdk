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
    @Test(arguments: [true, false])
    func holdAndResumeKeepTheCallConfiguration(endsFirst: Bool) async throws {
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
      await session.simulateExternalConfigurationChange()
      await framework.perform(.hold(id, onHold: false))
      _ = await events.next()
      await framework.send(.audioActivated)
      _ = await events.next()
      #expect(await session.value == .call)
      #expect(await audio.configuredCalls.map(\.id) == [id])
      if !endsFirst {
        await framework.send(.audioDeactivated)
        _ = await events.next()
      }
      await framework.perform(.end(id))
      _ = await events.next()
      if endsFirst {
        #expect(await session.value == .call)
        await framework.send(.audioDeactivated)
        _ = await events.next()
      }
      #expect(await session.value == .app)
      #expect(await session.applied == [.call, .call, .app])
    }

    @Test @VoIPActor func twoCallsRestoreOnlyAfterBothAreReleased() {
      let session = ConfigurationSession()
      let first = CallID(rawValue: "first")
      let second = CallID(rawValue: "second")
      session.remember()
      session.configuration.prepared(first, configuration: .call)
      session.configuration.activate()
      session.remember()
      session.configuration.prepared(second, configuration: .call)
      session.configuration.deactivate()
      session.configuration.release(first)
      #expect(session.value == .call)
      session.configuration.release(second)
      #expect(session.value == .app)
      #expect(session.applied == [.call, .app])
      session.configuration.release(second)
      session.configuration.deactivate()
      #expect(session.applied == [.call, .app])
    }

    @Test func twoPreparedCallsKeepAudioUntilBothEnd() async throws {
      let framework = FakeCallingFramework()
      let audio = FakeAudioSession()
      let session = ConfigurationSession()
      let client = try VoIPClient.start(
        framework: framework, media: ConfigurationMedia(session),
        audio: AudioSessionBridge(adapter: audio) { session.remember() })
      var events = client.events().makeAsyncIterator()
      let first = CallID(rawValue: "first")
      let second = CallID(rawValue: "second")
      for id in [first, second] {
        _ = await client.report(IncomingCall(id: id, parties: []))
        _ = await events.next()
        await framework.perform(.answer(id))
        _ = await events.next()
      }
      await framework.send(.audioActivated)
      _ = await events.next()
      await framework.perform(.end(first))
      _ = await events.next()
      await framework.send(.audioDeactivated)
      _ = await events.next()
      #expect(await session.value == .call)
      await framework.perform(.end(second))
      _ = await events.next()
      #expect(await session.value == .app)
      #expect(await audio.configuredCalls.map(\.id) == [first, second])
    }

    @Test @VoIPActor func rejoinCapturesTheConfigurationAfterRelease() {
      let session = ConfigurationSession()
      let id = CallID(rawValue: "rejoin")
      for _ in 0..<2 {
        session.remember()
        session.configuration.prepared(id, configuration: .call)
        session.configuration.activate()
        session.configuration.deactivate()
        session.configuration.release(id)
      }
      #expect(session.applied == [.call, .app, .call, .app])
    }

    @Test @VoIPActor func failedPreparationRestoresWithoutARelease() {
      let session = ConfigurationSession()
      session.remember()
      session.value = .call
      session.configuration.restoreIfIdle()
      #expect(session.value == .app)
    }
  }
}

@VoIPActor
private final class ConfigurationSession {
  enum Value: Sendable { case app, call }
  var value = Value.app
  var applied: [Value] = []
  lazy var configuration = CallAudioConfiguration<Value> { [weak self] value in
    self?.value = value
    self?.applied.append(value)
  }
  nonisolated init() {}
  func remember() { configuration.remember(value) }
  func simulateExternalConfigurationChange() { value = .app }
}

@VoIPActor
private final class ConfigurationMedia: CallMedia {
  let session: ConfigurationSession
  nonisolated init(_ session: ConfigurationSession) { self.session = session }
  func prepare(_ call: Call) async throws {
    session.value = .call
    session.configuration.prepared(call.id, configuration: .call)
  }
  func activate() { session.configuration.activate() }
  func deactivate() { session.configuration.deactivate() }
  func release(_ call: Call) { session.configuration.release(call.id) }
}
