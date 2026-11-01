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
  ///   - mustReport: Whether the SDK must report the push as a call.
  public func deliver(_ push: VoIPPush, mustReport: Bool = true) {
    deliver(push, PushCompletion(mustReport: mustReport, finish: finisher(for: push)))
  }

  /// Delivers a VoIP push to the SDK as the PushKit source does from iOS 26.4, returning when the
  /// SDK's push callback returns.
  ///
  /// The SDK must report the push when the system requires it or the app isn't active; see
  /// `PushCompletion.init(systemRequiresReport:appIsActive:finish:)`.
  ///
  /// - Parameters:
  ///   - push: The push to deliver.
  ///   - systemRequiresReport: Whether the system requires the push to be reported as a call.
  ///   - appIsActive: Whether the app is active, in the foreground.
  public func deliver(_ push: VoIPPush, systemRequiresReport: Bool, appIsActive: Bool) {
    deliver(
      push,
      PushCompletion(
        systemRequiresReport: systemRequiresReport, appIsActive: appIsActive,
        finish: finisher(for: push)))
  }

  private func deliver(_ push: VoIPPush, _ completion: PushCompletion) {
    guard let onPush else { preconditionFailure("The SDK hasn't attached the push source") }
    onPush(push, completion)
  }

  private func finisher(for push: VoIPPush) -> @VoIPActor @Sendable () -> Void {
    { [weak self] in self?.finished.append(push) }
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
