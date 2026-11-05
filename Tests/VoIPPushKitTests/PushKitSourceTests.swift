#if os(iOS)
  import Dispatch
  import PushKit
  import Testing
  import VoIPCore
  import VoIPTesting

  @testable import VoIPPushKit

  @Suite(.timeLimit(.minutes(1)))
  @VoIPActor
  struct PushKitSourceTests {
    @Test func attachRegistersSynchronouslyOnTheVoIPQueue() throws {
      dispatchPrecondition(condition: .onQueue(VoIPActor.queue))
      let source = PushKitSource(
        backgroundExecution: UnusedBackgroundExecution(), clock: TestClock(),
        backgroundSettle: .seconds(2))
      source.attach { _, completion in completion.finish() }

      let registry = try #require(source.registry)
      defer { registry.desiredPushTypes = [] }
      #expect(registry.delegate != nil)
      #expect(registry.desiredPushTypes == [.voIP])

      source.attach { _, completion in completion.finish() }
      #expect(source.registry === registry)
    }
  }

  private struct UnusedBackgroundExecution: PushBackgroundExecution {
    func begin(expiration: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
      {}
    }
  }
#endif
