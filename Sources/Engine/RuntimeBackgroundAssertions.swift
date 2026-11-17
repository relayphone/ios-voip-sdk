#if DEBUG && (os(macOS) || (os(iOS) && targetEnvironment(simulator))) && (SWIFT_PACKAGE || CKSIM_SDK_SOURCE)
  import Foundation
  #if SWIFT_PACKAGE
    import CKSimProtocol
    @_spi(Simulator) import VoIPCore
  #endif

  /// Invocation-local observed lifetimes. No policy allowance is inferred from UIKit returns.
  struct RuntimeBackgroundAssertions {
    private var assertions: [UUID: BackgroundAssertionSnapshot] = [:]
    private var lastObserved: [UUID: UInt64] = [:]
    private var unresolved = false

    var snapshot: BackgroundAssertionsSnapshot {
      BackgroundAssertionsSnapshot(
        hasUnresolvedObservations: unresolved,
        assertions: assertions.values.sorted { $0.id.uuidString < $1.id.uuidString })
    }

    /// Rejects incomplete histories conservatively, retaining the accepted state unchanged.
    mutating func observe(_ event: SimulatorBackgroundExecution.Event, epoch: UInt64, now: UInt64) {
      guard RuntimeBackgroundObservation(event, epoch: epoch, now: now) != nil else {
        unresolved = true
        return
      }
      let source: BackgroundAssertionSnapshot.Source
      switch event.source {
      case .applicationAssertion: source = .applicationAssertion
      case .sdkPushAssertion: source = .sdkPushAssertion
      }
      let time = event.uptimeNanoseconds
      if event.kind == .requested {
        guard assertions[event.id] == nil else {
          unresolved = true
          return
        }
        assertions[event.id] = BackgroundAssertionSnapshot(
          id: event.id, source: source, requestedAt: time)
        lastObserved[event.id] = time
        return
      }
      guard var assertion = assertions[event.id], assertion.source == source,
        let previous = lastObserved[event.id], time >= previous
      else {
        unresolved = true
        return
      }
      switch event.kind {
      case .requested: return
      case .began:
        guard assertion.beganAt == nil, assertion.deniedAt == nil else {
          unresolved = true
          return
        }
        assertion.beganAt = time
      case .denied:
        guard assertion.beganAt == nil, assertion.deniedAt == nil else {
          unresolved = true
          return
        }
        assertion.deniedAt = time
      case .expired:
        guard assertion.expiredAt == nil, assertion.deniedAt == nil else {
          unresolved = true
          return
        }
        assertion.expiredAt = time
      case .ended:
        guard assertion.beganAt != nil else {
          unresolved = true
          return
        }
        assertion.endedAt = assertion.endedAt ?? time
        assertion.endCount += 1
      }
      assertions[event.id] = assertion
      lastObserved[event.id] = time
    }
  }
#endif
