#if SWIFT_PACKAGE
  public import VoIPCore
#endif

/// A push source that delivers VoIP pushes when the test says, as PushKit does.
@VoIPActor
public final class FakePushSource: PushSource {
  /// The pushes the SDK finished, in the order it finished them.
  public private(set) var finished: [VoIPPush] = []

  private var onPush: (@VoIPActor (VoIPPush, PushCompletion) -> Void)?
  private var pending: [VoIPPush]

  /// Creates a fake push source.
  ///
  /// - Parameter pending: Pushes that arrived before the SDK attached, such as the VoIP push that
  ///   cold-launched the app. The source delivers them in order, each one required to be reported
  ///   as a call, as soon as the SDK attaches, as PushKit does once the app registers.
  public nonisolated init(pending: [VoIPPush] = []) {
    self.pending = pending
  }

  /// Delivers a VoIP push to the SDK, returning when the SDK's push callback returns.
  ///
  /// - Parameters:
  ///   - push: The push to deliver.
  ///   - mustReport: Whether the system requires the push to be reported as a call.
  public func deliver(_ push: VoIPPush, mustReport: Bool = true) {
    guard let onPush else { preconditionFailure("The SDK hasn't attached the push source") }
    onPush(
      push, PushCompletion(mustReport: mustReport) { [weak self] in self?.finished.append(push) })
  }

  // MARK: PushSource

  /// Starts delivering pushes to the SDK, beginning with the pending ones.
  public func attach(onPush: @escaping @VoIPActor (VoIPPush, PushCompletion) -> Void) {
    self.onPush = onPush
    let pending = self.pending
    self.pending = []
    for push in pending { deliver(push) }
  }
}
