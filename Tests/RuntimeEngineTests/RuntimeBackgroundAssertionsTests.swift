#if DEBUG && (os(macOS) || (os(iOS) && targetEnvironment(simulator)))
  import CKSimProtocol
  import Foundation
  import Testing
  @_spi(Simulator) import VoIPCore

  @testable import CKSimRuntime

  struct RuntimeBackgroundAssertionsTests {
    private struct Fixture {
      var observations = RuntimeBackgroundAssertions()
      let id = UUID()
      mutating func send(
        _ kind: SimulatorBackgroundExecution.Event.Kind, at time: UInt64,
        id other: UUID? = nil,
        source: SimulatorBackgroundExecution.Source = .applicationAssertion
      ) {
        observations.observe(
          .init(id: other ?? id, source: source, kind: kind, uptimeNanoseconds: time),
          epoch: 100, now: 1000)
      }
      var snapshot: BackgroundAssertionsSnapshot { observations.snapshot }
      var assertion: BackgroundAssertionSnapshot? { snapshot.assertions.first }
    }

    @Test func independentAttemptsRetainActualTimesAndSources() throws {
      var f = Fixture()
      let sdk = UUID()
      f.send(.requested, at: 100)
      f.send(.requested, at: 110, id: sdk, source: .sdkPushAssertion)
      f.send(.began, at: 120)
      f.send(.denied, at: 130, id: sdk, source: .sdkPushAssertion)
      let active = try #require(f.snapshot.assertions.first { $0.id == f.id })
      #expect(active.lifetime == .returnedIdentifier && active.requestedAt == 100)
      #expect(active.beganAt == 120 && active.source == .applicationAssertion)
      let denied = try #require(f.snapshot.assertions.first { $0.id == sdk })
      #expect(denied.lifetime == .denied && denied.deniedAt == 130)
      #expect(denied.beganAt == nil && denied.source == .sdkPushAssertion)
      #expect(!f.snapshot.hasUnresolvedObservations)
    }

    @Test func expirationBeforeBeginReturnCannotReviveTheAttempt() throws {
      var f = Fixture()
      f.send(.requested, at: 100)
      f.send(.expired, at: 110)
      #expect(f.assertion?.lifetime == .expired)
      f.send(.began, at: 120)
      let expired = try #require(f.assertion)
      #expect(expired.lifetime == .expired && expired.expiredAt == 110 && expired.beganAt == 120)
      f.send(.ended, at: 130)
      f.send(.ended, at: 140)
      #expect(f.assertion?.lifetime == .ended)
      #expect(f.assertion?.expiredAt == 110 && f.assertion?.endedAt == 130)
      #expect(f.assertion?.endCount == 2)
      #expect(!f.snapshot.hasUnresolvedObservations)
    }

    @Test func callbackAfterEndIsRetainedWithoutReopeningTheAttempt() {
      var f = Fixture()
      f.send(.requested, at: 100)
      f.send(.began, at: 110)
      f.send(.ended, at: 120)
      f.send(.expired, at: 130)
      #expect(f.assertion?.lifetime == .ended && f.assertion?.expiredAt == 130)
      #expect(!f.snapshot.hasUnresolvedObservations)
    }

    @Test(arguments: [UInt64(99), 1001])
    func invalidObservationTimeMakesTheHistoryUnusable(time: UInt64) {
      var f = Fixture()
      f.send(.requested, at: time)
      #expect(f.snapshot.assertions.isEmpty && f.snapshot.hasUnresolvedObservations)
      f.send(.requested, at: 100)
      f.send(.began, at: 110)
      #expect(f.snapshot.hasUnresolvedObservations)
    }

    @Test(arguments: [
      SimulatorBackgroundExecution.Event.Kind.began, .denied, .expired, .ended,
    ])
    func missingRequestNeverCreatesAUsableAttempt(kind: SimulatorBackgroundExecution.Event.Kind) {
      var f = Fixture()
      f.send(kind, at: 100)
      #expect(f.snapshot.assertions.isEmpty && f.snapshot.hasUnresolvedObservations)
    }

    @Test func sourceMismatchBackwardsTimeAndDuplicateBeginLeaveStateUnchanged() {
      var f = Fixture()
      f.send(.requested, at: 100)
      f.send(.began, at: 120)
      let before = f.snapshot.assertions
      f.send(.ended, at: 130, source: .sdkPushAssertion)
      f.send(.expired, at: 119)
      f.send(.requested, at: 140)
      f.send(.began, at: 140)
      f.send(.denied, at: 140)
      #expect(f.snapshot.assertions == before && f.snapshot.hasUnresolvedObservations)
    }

    @Test func denialAndAnUnreturnedRequestCannotBeEnded() {
      var f = Fixture()
      f.send(.requested, at: 100)
      f.send(.ended, at: 110)
      #expect(f.assertion?.lifetime == .requested && f.assertion?.endCount == 0)
      f.send(.denied, at: 120)
      f.send(.expired, at: 130)
      f.send(.began, at: 140)
      #expect(f.assertion?.lifetime == .denied && f.assertion?.expiredAt == nil)
      #expect(f.snapshot.hasUnresolvedObservations)
    }

    @Test func equalTimesRemainOrderedByTheObservedCallsAndNewInvocationIsEmpty() {
      var f = Fixture()
      f.send(.requested, at: 100)
      f.send(.expired, at: 100)
      f.send(.began, at: 100)
      f.send(.ended, at: 100)
      #expect(f.assertion?.lifetime == .ended && f.assertion?.expiredAt == 100)
      #expect(!f.snapshot.hasUnresolvedObservations)
      let next = RuntimeBackgroundAssertions().snapshot
      #expect(next.assertions.isEmpty && !next.hasUnresolvedObservations)
    }
  }
#endif
