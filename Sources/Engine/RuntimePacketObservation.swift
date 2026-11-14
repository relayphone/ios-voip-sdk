#if DEBUG && (os(macOS) || (os(iOS) && targetEnvironment(simulator))) && (SWIFT_PACKAGE || CKSIM_SDK_SOURCE)
  import Foundation
  #if SWIFT_PACKAGE
    import VoIPCore
  #endif

  /// Projects packet observations onto the runtime's uptime-based journal clock.
  struct RuntimePacketObservation {
    let name: String
    let callID: String
    let callUUID: UUID
    let observedAtMS: Double

    init?(
      _ event: MediaTransportEvent, receivedAt: SuspendingClock.Instant, elapsed: Duration
    ) {
      let age = event.observedAt.duration(to: receivedAt)
      guard age >= .zero, elapsed >= age else { return nil }
      switch event.kind {
      case .firstPacketReceived: name = "sdk.firstPacketReceived"
      case .firstPacketSent: name = "sdk.firstPacketSent"
      }
      callID = event.callID.rawValue
      callUUID = deviceUUID(for: event.callID)
      let parts = (elapsed - age).components
      observedAtMS = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
  }
#endif
