#if DEBUG && (os(macOS) || (os(iOS) && targetEnvironment(simulator)))
  import Dispatch
  import Foundation
  import Synchronization

  /// Internal simulator instrumentation; never compiled into a device build.
  @_spi(Simulator) public enum SimulatorLifecycle {
    /// A lifecycle observation made synchronously by the SDK engine.
    public struct Event: Sendable {
      /// The lifecycle edge, or an ordinary state update.
      public enum Kind: String, Sendable {
        case state, accept, connected, ended, joinDeadlineExpired
      }
      public let kind: Kind
      public let call: Call
      public let uptimeNanoseconds: UInt64
    }
    private static let sink = Mutex<(@Sendable (Event) -> Void)?>(nil)

    /// Installs or removes the in-process runtime's journal sink.
    public static func install(_ receive: (@Sendable (Event) -> Void)?) {
      sink.withLock { $0 = receive }
    }

    static func record(_ call: Call, _ kind: Event.Kind = .state) {
      let receive = sink.withLock { $0 }
      receive?(
        Event(kind: kind, call: call, uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds))
    }
  }
#endif
