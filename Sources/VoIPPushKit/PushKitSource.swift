#if os(iOS)
  public import Foundation
  import PushKit
  public import VoIPCore
  import VoIPPushDelivery

  /// A push source that receives the app's VoIP pushes from PushKit.
  ///
  /// Create it when the app launches and pass it to
  /// `VoIPClient.start(framework:media:push:configuration:clock:)`, which attaches it before any
  /// push can arrive. PushKit delivers pushes on `VoIPActor`, so the SDK reports a push's call
  /// before the push callback returns, as Apple requires.
  ///
  /// Register the push token with your servers from ``tokens()``:
  ///
  /// ```swift
  /// let push = PushKitSource()
  /// let client = try VoIPClient.start(
  ///   framework: LiveCommunicationKitAdapter(), media: media, push: push)
  /// Task {
  ///   for await token in push.tokens() {
  ///     await server.updateVoIPPushToken(token)
  ///   }
  /// }
  /// ```
  @VoIPActor
  public final class PushKitSource: PushSource {
    /// How long PushKit waits for the SDK to finish a push before the source finishes it anyway.
    ///
    /// The system terminates an app that hasn't reported a call about 4.4 seconds after a VoIP
    /// push arrives, so the SDK reports at once and this only bounds a push whose report never
    /// completes.
    static let watchdog: TimeInterval = 4

    private let decode: @Sendable (Data) -> VoIPPush
    private let tokenUpdates = TokenUpdates()
    private var registry: PKPushRegistry?
    private var delegate: RegistryDelegate?

    /// Creates a push source that decodes pushes with the given function.
    ///
    /// - Parameter decode: Decodes a push's JSON payload. It runs on `VoIPActor`
    ///   before the SDK reports the push's call, so it must return quickly. Return
    ///   `VoIPPush.unrecognized` for a payload it can't decode. Defaults to the SDK's
    ///   format, `VoIPPush.init(defaultFormat:)`.
    public nonisolated init(
      decode: @escaping @Sendable (Data) -> VoIPPush = VoIPPush.init(defaultFormat:)
    ) {
      self.decode = decode
    }

    /// Returns a new stream of the VoIP push token, which the app registers with its servers.
    ///
    /// The stream starts with the current token, when PushKit has issued one, then yields each
    /// new token. It yields `nil` when PushKit invalidates the token; stop sending VoIP pushes
    /// to this device until a new token arrives.
    public nonisolated func tokens() -> AsyncStream<Data?> {
      tokenUpdates.stream()
    }

    /// Registers for VoIP pushes and delivers each one to the SDK.
    public func attach(onPush: @escaping @VoIPActor (VoIPPush, PushCompletion) -> Void) {
      guard registry == nil else { return }
      let delegate = RegistryDelegate(source: self, onPush: onPush)
      let registry = PKPushRegistry(queue: VoIPActor.queue)
      registry.delegate = delegate
      registry.desiredPushTypes = [.voIP]
      self.delegate = delegate
      self.registry = registry
    }

    fileprivate func receive(
      _ payload: PKPushPayload, mustReport: Bool, completion: @escaping () -> Void,
      onPush: @VoIPActor (VoIPPush, PushCompletion) -> Void
    ) {
      let delivery = VSPushCompletion(completion: completion, watchdog: Self.watchdog)
      guard payload.type == .voIP else { return delivery.finish() }
      let push =
        if let json = try? JSONSerialization.data(withJSONObject: payload.dictionaryPayload) {
          decode(json)
        } else {
          VoIPPush.unrecognized
        }
      onPush(push, PushCompletion(mustReport: mustReport) { delivery.finish() })
    }

    fileprivate func tokenChanged(_ token: Data?) {
      tokenUpdates.send(token)
    }
  }

  /// Receives PushKit's callbacks on `VoIPActor`, the registry's queue.
  @VoIPActor
  private final class RegistryDelegate: NSObject, @preconcurrency PKPushRegistryDelegate {
    private weak var source: PushKitSource?
    private let onPush: @VoIPActor (VoIPPush, PushCompletion) -> Void

    init(source: PushKitSource, onPush: @escaping @VoIPActor (VoIPPush, PushCompletion) -> Void) {
      self.source = source
      self.onPush = onPush
    }

    func pushRegistry(
      _ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType
    ) {
      guard type == .voIP else { return }
      source?.tokenChanged(credentials.token)
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
      guard type == .voIP else { return }
      source?.tokenChanged(nil)
    }

    func pushRegistry(
      _ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
      for type: PKPushType, completion: @escaping () -> Void
    ) {
      // Before iOS 26.4, every VoIP push must be reported as a call.
      deliver(payload, mustReport: true, completion: completion)
    }

    @available(iOS 26.4, *)
    func pushRegistry(
      _ registry: PKPushRegistry, didReceiveIncomingVoIPPushWith payload: PKPushPayload,
      metadata: PKVoIPPushMetadata, withCompletionHandler completion: @escaping () -> Void
    ) {
      deliver(payload, mustReport: metadata.mustReport, completion: completion)
    }

    private func deliver(
      _ payload: PKPushPayload, mustReport: Bool, completion: @escaping () -> Void
    ) {
      guard let source else { return completion() }
      source.receive(payload, mustReport: mustReport, completion: completion, onPush: onPush)
    }
  }
#endif
