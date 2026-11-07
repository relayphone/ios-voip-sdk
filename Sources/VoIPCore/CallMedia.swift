/// The app's real-time audio and video transport for calls.
///
/// The SDK prepares a call's media before it completes the answer, start or join that makes the
/// call take part on this device, then starts and stops audio as the system activates and
/// deactivates the audio session, or interrupts it.
///
/// ## Media that lives on the main actor
///
/// `prepare` is async, so it can await a main-actor transport. In contrast, `activate()` and
/// `deactivate()` run synchronously on `VoIPActor`. Don't start a separate
/// `Task { @MainActor in … }` in each callback: those unstructured tasks can reorder activation
/// and deactivation. Yield commands into one `AsyncStream` instead, and let a single main-actor
/// consumer apply them in order. Track whether audio is active only in that consumer.
///
/// Give each preparation attempt a token and carry it through preparation and every command.
/// A new attempt supersedes the old one, even when an old preparation ignores cancellation.
/// Check the token after suspension before publishing prepared objects, and discard commands
/// for an older attempt. A call ID alone isn't enough: the same call can retry joining.
///
/// This adapter uses only the SDK's `CallMedia` and `Call` types plus Swift concurrency. Its
/// `MainActorTransport` seam represents the main-actor audio objects. Implementations must check
/// the attempt token before committing objects after an asynchronous preparation. The consumer
/// checks it again before accepting completion, and before applying audio commands. A replacement
/// starts inactive through the same stream; preparation never changes `audioActive` directly.
/// This example models one replaceable transport. Media serving several calls concurrently needs
/// separate preparation attempts per call and session-wide audio commands for all prepared calls.
///
/// ```swift
/// /// A transport whose audio objects belong to the main actor.
/// @MainActor
/// protocol MainActorTransport: Sendable {
///   func prepare(_ call: Call, attempt: UInt64) async throws
///   func setAudioActive(_ active: Bool)
/// }
///
/// @VoIPActor
/// final class MainActorMedia: CallMedia {
///   struct AudioCommand: Sendable {
///     let attempt: UInt64
///     let active: Bool
///   }
///
///   @MainActor
///   final class Consumer {
///     let transport: any MainActorTransport
///     let commands: AsyncStream<AudioCommand>.Continuation
///     private var attempt: UInt64 = 0
///     private(set) var audioActive = false
///
///     init(
///       transport: any MainActorTransport,
///       commands: AsyncStream<AudioCommand>.Continuation
///     ) {
///       self.transport = transport
///       self.commands = commands
///     }
///
///     func prepare(_ call: Call, attempt: UInt64) async throws {
///       guard attempt > self.attempt else { throw CancellationError() }
///       self.attempt = attempt
///       // A replacement transport starts inactive. Only the consumer changes audio state.
///       commands.yield(AudioCommand(attempt: attempt, active: false))
///       try await transport.prepare(call, attempt: attempt)
///       try Task.checkCancellation()
///       guard attempt == self.attempt else { throw CancellationError() }
///     }
///
///     func consume(_ stream: AsyncStream<AudioCommand>) async {
///       for await command in stream {
///         guard command.attempt == attempt else { continue }
///         audioActive = command.active
///         transport.setAudioActive(audioActive)
///       }
///     }
///   }
///
///   private var attempt: UInt64 = 0
///   private let commands: AsyncStream<AudioCommand>.Continuation
///   private let consumer: Consumer
///   private let task: Task<Void, Never>
///
///   init(transport: any MainActorTransport) async {
///     let (stream, commands) = AsyncStream<AudioCommand>.makeStream()
///     self.commands = commands
///     let consumer = await Consumer(transport: transport, commands: commands)
///     self.consumer = consumer
///     task = Task { @MainActor in await consumer.consume(stream) }
///   }
///
///   deinit {
///     commands.finish()
///     task.cancel()
///   }
///
///   func prepare(_ call: Call) async throws {
///     attempt += 1
///     try await consumer.prepare(call, attempt: attempt)
///   }
///
///   func activate() {
///     commands.yield(AudioCommand(attempt: attempt, active: true))
///   }
///
///   func deactivate() {
///     commands.yield(AudioCommand(attempt: attempt, active: false))
///   }
///
///   /// Drain the stream when the owner is finished with the adapter.
///   func finish() async {
///     commands.finish()
///     await task.value
///   }
/// }
/// ```
///
/// The one task above owns the consumer's lifetime; it isn't recreated for each audio callback.
/// Keep the adapter alive while the client uses it. After stopping the client, call `finish()`
/// to drain queued commands. Releasing the adapter also finishes the stream and cancels its task.
/// The stream uses its default unbounded buffer so that neither activation nor deactivation is
/// dropped. The executable example and its ordering and stale-attempt tests live in
/// `Tests/VoIPCoreTests/MainActorMedia.swift` and `MainActorMediaTests.swift`.
@VoIPActor
public protocol CallMedia: Sendable {
  /// Prepares a call's media, such as connecting to its room, before the call takes part on this
  /// device.
  ///
  /// Don't use the microphone or speaker yet; wait for ``activate()``. The SDK cancels the task
  /// when the call stops waiting for its media, for example because it ended. When preparation
  /// throws, or takes longer than ``Deadlines/mediaPreparation``, the call ends with
  /// ``CallFailure/media``, or a join returns to its call preview.
  ///
  /// - Parameter call: The call whose media to prepare.
  func prepare(_ call: Call) async throws

  /// Starts using the microphone and speaker, now that the system activated the audio session.
  func activate()

  /// Stops using the audio session, which the system deactivated or interrupted, or which the
  /// media services reset.
  ///
  /// The SDK calls it only after ``activate()``, once per activation. After
  /// ``CallEvent/mediaServicesReset``, recreate the media's audio objects before the next
  /// ``activate()``.
  func deactivate()
}
