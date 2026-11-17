#if DEBUG && (os(macOS) || (os(iOS) && targetEnvironment(simulator)))
  import Dispatch
  public import Foundation
  import Synchronization

  /// Explicit adapter instrumentation, excluded from device and Release builds.
  @_spi(Simulator) public enum SimulatorBackgroundExecution {
    /// The adapter making a real UIKit request, not an exhaustive list of execution grants.
    public enum Source: String, Sendable { case applicationAssertion, sdkPushAssertion }

    /// One synchronous adapter boundary. A returned identifier does not prove a system grant.
    public struct Event: Equatable, Sendable {
      /// Requests and returns are distinct because expiration may run before begin returns.
      public enum Kind: String, Sendable { case requested, began, denied, expired, ended }
      /// Correlates one begin attempt independently of UIKit's opaque identifier.
      public let id: UUID
      /// The explicitly instrumented adapter.
      public let source: Source
      /// The observed operation, never a modeled expiration or process decision.
      public let kind: Kind
      /// System monotonic uptime at the boundary.
      public let uptimeNanoseconds: UInt64

      /// Constructs a typed boundary for journal projection and controlled tests.
      public init(id: UUID, source: Source, kind: Kind, uptimeNanoseconds: UInt64) {
        self.id = id
        self.source = source
        self.kind = kind
        self.uptimeNanoseconds = uptimeNanoseconds
      }
    }

    private static let sink = Mutex<(@Sendable (Event) -> Void)?>(nil)

    /// Installs or removes the embedded runtime's observation sink.
    public static func install(_ receive: (@Sendable (Event) -> Void)?) {
      sink.withLock { $0 = receive }
    }

    /// Transparently observes an adapter's real begin, expiration and end operations.
    ///
    /// Return nil from `begin` only for a denied request. The owner must call the returned
    /// end operation exactly once for every valid identifier, including after expiration.
    /// This bridge neither suppresses duplicate operations nor invents an allowance or due time.
    public static func begin<Identifier: Sendable>(
      source: Source,
      begin: (@escaping @Sendable () -> Void) -> Identifier?,
      end: @escaping @Sendable (Identifier) -> Void,
      expiration: @escaping @Sendable () -> Void
    ) -> @Sendable () -> Void {
      let id = UUID()
      let record: @Sendable (Event.Kind) -> Void = { kind in
        let event = Event(
          id: id, source: source, kind: kind,
          uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
        let receive = sink.withLock { $0 }
        receive?(event)
      }
      record(.requested)
      let identifier = begin {
        record(.expired)
        expiration()
      }
      guard let identifier else {
        record(.denied)
        return {}
      }
      record(.began)
      return {
        end(identifier)
        record(.ended)
      }
    }
  }
#endif
