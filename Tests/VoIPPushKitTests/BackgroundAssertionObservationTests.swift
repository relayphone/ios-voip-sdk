#if DEBUG && (os(macOS) || (os(iOS) && targetEnvironment(simulator)))
  import Foundation
  import Synchronization
  import Testing
  @_spi(Simulator) import VoIPCore
  import VoIPTesting

  @testable import VoIPPushKit

  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct BackgroundAssertionObservationTests {
    private typealias Observation = SimulatorBackgroundExecution.Event

    private final class Recorder: Sendable {
      let events = Mutex<[Observation]>([])
      init() {
        SimulatorBackgroundExecution.install { [self] event in
          events.withLock { $0.append(event) }
        }
      }
      var history: [Observation] { events.withLock { $0 } }
    }

    private final class Execution: PushBackgroundExecution, Sendable {
      let source: SimulatorBackgroundExecution.Source
      let denied: Bool
      let expireBeforeReturn: Bool
      let callback = Mutex<(@Sendable () -> Void)?>(nil)
      let endIDs = Mutex<[Int]>([])

      init(
        source: SimulatorBackgroundExecution.Source = .sdkPushAssertion,
        denied: Bool = false, expireBeforeReturn: Bool = false
      ) {
        self.source = source
        self.denied = denied
        self.expireBeforeReturn = expireBeforeReturn
      }

      func begin(expiration: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        SimulatorBackgroundExecution.begin(
          source: source,
          begin: { expiration -> Int? in
            if denied { return nil }
            callback.withLock { $0 = expiration }
            if expireBeforeReturn { expiration() }
            return 42
          }, end: { id in self.endIDs.withLock { $0.append(id) } }, expiration: expiration)
      }

      func expire() { callback.withLock { $0 }?() }
      var ended: [Int] { endIDs.withLock { $0 } }
    }

    @Test(arguments: [SimulatorBackgroundExecution.Source.applicationAssertion, .sdkPushAssertion])
    func bothAdaptersPreserveIdentifierAndOperations(source: SimulatorBackgroundExecution.Source)
      throws
    {
      let recorder = Recorder()
      defer { SimulatorBackgroundExecution.install(nil) }
      let execution = Execution(source: source)
      let expired = Mutex(false)
      let end = execution.begin { expired.withLock { $0 = true } }
      execution.expire()
      #expect(expired.withLock { $0 })
      #expect(execution.ended.isEmpty)
      end()
      let events = recorder.history
      #expect(events.map(\.kind) == [.requested, .began, .expired, .ended])
      #expect(Set(events.map(\.id)).count == 1)
      #expect(events.allSatisfy { $0.source == source })
      #expect(events.map(\.uptimeNanoseconds) == events.map(\.uptimeNanoseconds).sorted())
      #expect(execution.ended == [42])
    }

    @Test func denialHasNoExpirationOrEndOperation() {
      let recorder = Recorder()
      defer { SimulatorBackgroundExecution.install(nil) }
      let execution = Execution(denied: true)
      let expired = Mutex(false)
      let end = execution.begin { expired.withLock { $0 = true } }
      end()
      execution.expire()
      #expect(!expired.withLock { $0 })
      #expect(execution.ended.isEmpty)
      #expect(recorder.history.map(\.kind) == [.requested, .denied])
      #expect(Set(recorder.history.map(\.id)).count == 1)
    }

    @Test(arguments: [false, true])
    func realPushOwnerEndsOnceEvenWhenExpirationPrecedesReturn(beforeReturn: Bool) {
      let recorder = Recorder()
      defer { SimulatorBackgroundExecution.install(nil) }
      let execution = Execution(expireBeforeReturn: beforeReturn)
      let task = PushBackgroundTask(
        execution: execution, clock: TestClock(), settle: .seconds(2))
      if !beforeReturn { execution.expire() }
      task.completed()
      #expect(execution.ended == [42])
      #expect(
        recorder.history.map(\.kind)
          == (beforeReturn
            ? [.requested, .expired, .began, .ended] : [.requested, .began, .expired, .ended]))
    }

    @Test func overlappingRequestsStayDistinctAndDuplicateEndsRemainVisible() {
      let recorder = Recorder()
      defer { SimulatorBackgroundExecution.install(nil) }
      let execution = Execution()
      let first = execution.begin {}
      let second = execution.begin {}
      second()
      first()
      first()
      let events = recorder.history
      let ids = events.filter { $0.kind == .requested }.map(\.id)
      #expect(ids.count == 2 && ids[0] != ids[1])
      #expect(events.filter { $0.kind == .ended }.map(\.id) == [ids[1], ids[0], ids[0]])
      #expect(execution.ended == [42, 42, 42])
    }

    @Test func sinkCanUninstallItselfWithoutBlockingRealOperations() {
      let recorder = Recorder()
      defer { SimulatorBackgroundExecution.install(nil) }
      SimulatorBackgroundExecution.install { event in
        recorder.events.withLock { $0.append(event) }
        SimulatorBackgroundExecution.install(nil)
      }
      let execution = Execution()
      let end = execution.begin {}
      execution.expire()
      end()
      #expect(recorder.history.map(\.kind) == [.requested])
      #expect(execution.ended == [42])
    }

    @Test func endIsObservedOnlyAfterTheRealEndOperationReturns() {
      let execution = Execution()
      let observations = Mutex(0)
      SimulatorBackgroundExecution.install { event in
        if event.kind == .ended {
          #expect(execution.ended == [42])
          observations.withLock { $0 += 1 }
        }
      }
      defer { SimulatorBackgroundExecution.install(nil) }
      execution.begin {}()
      #expect(observations.withLock { $0 } == 1)
    }

    #if os(iOS)
      @Test(arguments: [false, true]) @MainActor
      func realUIKitAdaptersPublishOnlyTheirOwnBoundaries(fixture: Bool) throws {
        let recorder = Recorder()
        defer { SimulatorBackgroundExecution.install(nil) }
        let end =
          fixture
          ? UIKitBackgroundExecution().begin(expiration: {})
          : UIKitPushBackgroundExecution().begin(expiration: {})
        end()
        let events = recorder.history
        #expect(events.first?.kind == .requested)
        #expect(Set(events.map(\.id)).count == 1)
        #expect(
          events.allSatisfy { $0.source == (fixture ? .applicationAssertion : .sdkPushAssertion) })
        // UIKit may deny real requests. Only a valid return requires an owner end.
        if events.contains(where: { $0.kind == .began }) {
          #expect(events.filter { $0.kind == .ended }.count == 1)
          #expect(!events.contains { $0.kind == .denied })
        } else {
          #expect(events.map(\.kind) == [.requested, .denied])
        }
      }
    #endif
  }
#endif
