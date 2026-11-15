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

    // Host delay has elapsed before staging. Cold duplicates retain their wire identities.
    init(launch envelope: PushLaunchEnvelope) {
      deliveries = envelope.deliveryIDs.enumerated().map { index, id in
        Delivery(
          id: id, offset: .milliseconds(index * envelope.delivery.spacingMS),
          dropped: envelope.delivery.drop)
      }
    }

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

    // Registry startup may be arbitrarily slow. Anchor duplicates to actual delegate entry.
    func runAfterFirstEntry<C: Clock>(
      clock: C, firstEntry: @Sendable () async throws -> C.Instant,
      deliver: @Sendable (Delivery) -> Void
    ) async throws where C.Duration == Duration {
      guard let first = deliveries.first else { return }
      try Task.checkCancellation()
      if first.dropped {
        for delivery in deliveries {
          try Task.checkCancellation()
          deliver(delivery)
        }
        return
      }
      deliver(first)
      let start = try await firstEntry()
      for delivery in deliveries.dropFirst() {
        try await clock.sleep(until: start.advanced(by: delivery.offset), tolerance: nil)
        try Task.checkCancellation()
        deliver(delivery)
      }
    }
  }
#endif
