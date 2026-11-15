/// Shared adapter implementation detail; applications implement ``CallMedia/transportEvents()``.
@_spi(MediaTransport) @MainActor public enum MediaPacketSampler {
  /// Polls only directions that have not yet been observed, until both are known or time runs out.
  /// The synchronous sample must return promptly; unavailable statistics return false.
  /// Readiness is checked within the same deadline, before each sample.
  public static func observe<C: Clock>(
    callID: CallID, clock: C, interval: Duration = .milliseconds(250),
    timeout: Duration = .seconds(30),
    ready: @MainActor () -> Bool = { true },
    sample: @MainActor (_ needsReceived: Bool, _ needsSent: Bool) -> (received: Bool, sent: Bool),
    emit: @MainActor (MediaTransportEvent) -> Void
  ) async where C.Duration == Duration {
    guard interval > .zero, timeout > .zero else { return }
    let deadline = clock.now.advanced(by: timeout)
    var received = false
    var sent = false
    while !Task.isCancelled, clock.now < deadline {
      if !ready() {
        do {
          try await clock.sleep(
            until: min(clock.now.advanced(by: interval), deadline), tolerance: nil)
        } catch { return }
        continue
      }
      let observation = sample(!received, !sent)
      let now = SuspendingClock.now
      if !received, observation.received {
        received = true
        emit(.init(callID: callID, kind: .firstPacketReceived, observedAt: now))
      }
      if !sent, observation.sent {
        sent = true
        emit(.init(callID: callID, kind: .firstPacketSent, observedAt: now))
      }
      if received && sent { return }
      do {
        try await clock.sleep(
          until: min(clock.now.advanced(by: interval), deadline), tolerance: nil)
      } catch { return }
    }
  }
}
