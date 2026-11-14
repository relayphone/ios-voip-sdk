#if DEBUG && (os(macOS) || targetEnvironment(simulator))
  import Synchronization
  import Testing
  import VoIPTesting
  @_spi(Simulator) @testable import VoIPCore

  extension EngineTests {
    @MainActor struct SimulatorLifecycleTests {
      @Test func recordsAcceptConnectAndEndFromTheRealEngine() async throws {
        let rows = Mutex<[SimulatorLifecycle.Event]>([])
        SimulatorLifecycle.install { row in rows.withLock { $0.append(row) } }
        defer { SimulatorLifecycle.install(nil) }
        let h = try Harness()
        try await h.connect()
        await h.client.receive(.endedRemotely, for: callID, eventID: e3)
        #expect(try await h.next() == .ended(callID, .endedRemotely))
        let events = rows.withLock { $0.filter { $0.call.id == callID && $0.kind != .state } }
        #expect(events.map(\.kind) == [.accept, .connected, .ended])
        #expect(events.last?.call.status == .ended(.endedRemotely))
        #expect(events.map(\.uptimeNanoseconds) == events.map(\.uptimeNanoseconds).sorted())
      }
      @Test func preparationDeadlineIsRecordedBeforeTheEnd() async throws {
        let rows = Mutex<[SimulatorLifecycle.Event]>([])
        SimulatorLifecycle.install { row in rows.withLock { $0.append(row) } }
        defer { SimulatorLifecycle.install(nil) }
        let h = try Harness()
        try await h.ring()
        let media = h.media
        await onVoIPActor { media.preparation = .wait }
        _ = await h.framework.perform(.answer(callID))
        h.clock.advance(by: Deadlines().mediaPreparation)
        #expect(try await h.next() == .ended(callID, .failed(.media)))
        #expect(
          rows.withLock { $0.filter { $0.call.id == callID && $0.kind != .state }.map(\.kind) }
            == [.accept, .joinDeadlineExpired, .ended])
      }
    }
  }
#endif
