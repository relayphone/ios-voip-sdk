public import Dispatch

/// The global actor that holds every call's state.
///
/// The SDK, the calling framework and the push source all run on this actor, so that a VoIP push
/// is reported, and an action is performed, without waiting for another thread. Its executor is
/// ``queue``, which adapters pass to the system frameworks as their delegate queue.
@globalActor
public actor VoIPActor {
  /// The shared actor instance.
  public static let shared = VoIPActor()

  /// The serial queue that runs the actor's work.
  ///
  /// Adapters pass it to the system as a delegate queue, so that PushKit and CallKit callbacks
  /// arrive on the actor and can use `VoIPActor.assumeIsolated`.
  public static let queue = DispatchSerialQueue(label: "VoIPCore.VoIPActor", qos: .userInitiated)

  /// The executor that runs the actor's work on ``queue``.
  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    Self.queue.asUnownedSerialExecutor()
  }
}
