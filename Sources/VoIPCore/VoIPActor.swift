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
  /// arrive on the actor and can use ``assumeIsolated(_:file:line:)``.
  public static let queue = DispatchSerialQueue(label: "VoIPCore.VoIPActor", qos: .userInitiated)

  /// The executor that runs the actor's work on ``queue``.
  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    Self.queue.asUnownedSerialExecutor()
  }

  /// Runs work on the actor from a synchronous callback that the system makes on ``queue``, such
  /// as the completion of a CallKit report, without hopping.
  ///
  /// Like `MainActor.assumeIsolated(_:file:line:)`, it stops the app when the caller isn't
  /// running on ``queue``.
  ///
  /// - Parameters:
  ///   - operation: The work to run on the actor.
  ///   - file: The file to name if the caller isn't running on the actor.
  ///   - line: The line to name if the caller isn't running on the actor.
  /// - Returns: The work's result.
  public static func assumeIsolated<T: Sendable>(
    _ operation: @VoIPActor () throws -> T, file: StaticString = #fileID, line: UInt = #line
  ) rethrows -> T {
    shared.preconditionIsolated(
      "The caller isn't running on VoIPActor.queue", file: file, line: line)
    // The check above makes the actor's isolation hold, which the type system can't see.
    return try withoutActuallyEscaping(operation) { operation in
      try unsafeBitCast(operation, to: (() throws -> T).self)()
    }
  }
}
