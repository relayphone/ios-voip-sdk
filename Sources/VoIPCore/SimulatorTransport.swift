#if DEBUG && (os(macOS) || (os(iOS) && targetEnvironment(simulator)))
  import Synchronization

  /// Optional in-process journal bridge, excluded from devices and Release.
  @_spi(Simulator) public enum SimulatorTransport {
    private static let sink = Mutex<(@Sendable (MediaTransportEvent) -> Void)?>(nil)

    /// Installs or removes the embedded runtime's packet sink.
    public static func install(_ receive: (@Sendable (MediaTransportEvent) -> Void)?) {
      sink.withLock { $0 = receive }
    }

    static func record(_ event: MediaTransportEvent) {
      let receive = sink.withLock { $0 }
      receive?(event)
    }
  }
#endif
