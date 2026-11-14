#if os(macOS) || (os(iOS) && targetEnvironment(simulator))
  import Foundation
  #if SWIFT_PACKAGE
    import CKSimProtocol
  #endif

  // The request ID identifies the original; every additional attempt has its own push ID.
  struct PushDeliverySchedule: Sendable {
    struct Delivery: Sendable {
      let id: UUID
      let offset: Duration
      let dropped: Bool
    }
    let deliveries: [Delivery]

    init(id: UUID, faults: PushDeliveryFaults) {
      deliveries = (0...faults.duplicate).map { index in
        Delivery(
          id: index == 0 ? id : UUID(),
          offset: .milliseconds(faults.delayMS + index * faults.spacingMS), dropped: faults.drop)
      }
    }

    // Anchor every delivery to acceptance, rather than adding callback or executor delays.
    func run<C: Clock>(
      clock: C, startingAt start: C.Instant, deliver: @Sendable (Delivery) -> Void
    ) async throws where C.Duration == Duration {
      for delivery in deliveries {
        try await clock.sleep(until: start.advanced(by: delivery.offset), tolerance: nil)
        try Task.checkCancellation()
        deliver(delivery)
      }
    }
  }
#endif
