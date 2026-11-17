#if DEBUG && (os(macOS) || (os(iOS) && targetEnvironment(simulator))) && (SWIFT_PACKAGE || CKSIM_SDK_SOURCE)
  import Foundation
  #if SWIFT_PACKAGE
    @_spi(Simulator) import VoIPCore
  #endif

  /// Typed projection onto the existing runtime journal; never an execution grant.
  struct RuntimeBackgroundObservation {
    let name: String
    let id: UUID
    let source: SimulatorBackgroundExecution.Source
    let uptimeNanoseconds: UInt64

    init?(_ event: SimulatorBackgroundExecution.Event, epoch: UInt64, now: UInt64) {
      guard event.uptimeNanoseconds >= epoch, event.uptimeNanoseconds <= now else { return nil }
      name = "backgroundAssertion.\(event.kind.rawValue)"
      id = event.id
      source = event.source
      uptimeNanoseconds = event.uptimeNanoseconds
    }
  }
#endif
