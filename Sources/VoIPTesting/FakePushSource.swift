public import VoIPCore

/// A push source that delivers VoIP pushes when the test says, as PushKit does.
@VoIPActor
public final class FakePushSource: PushSource {
  /// The pushes the SDK finished, in the order it finished them.
  public private(set) var finished: [VoIPPush] = []

  private var onPush: (@VoIPActor (VoIPPush, PushCompletion) -> Void)?

  /// Creates a fake push source.
  public nonisolated init() {}

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

  /// Starts delivering pushes to the SDK.
  public func attach(onPush: @escaping @VoIPActor (VoIPPush, PushCompletion) -> Void) {
    self.onPush = onPush
  }
}
