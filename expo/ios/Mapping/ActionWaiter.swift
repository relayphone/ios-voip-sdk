import Foundation

#if SWIFT_PACKAGE
  import VoIPCore
#endif

/// A request that waits for the SDK's event that carries it out.
@MainActor
final class ActionWaiter {
  let action: Action
  var failure: CommandError?
  /// The SDK's placement and media preparation bounds, with a delivery margin. The SDK exposes
  /// no separate action deadline to add to these bounds.
  private let limit: Duration
  private let clock: any Clock<Duration>
  private var isFinished = false
  private var continuation: CheckedContinuation<Void, Never>?
  private var expiry: Task<Void, Never>?

  init(
    _ action: Action, deadlines: Deadlines, clock: any Clock<Duration> = ContinuousClock()
  ) {
    self.action = action
    limit = deadlines.placement + deadlines.mediaPreparation + .seconds(5)
    self.clock = clock
  }

  /// Whether the request starts or joins the call, and so waits for the app to place it.
  func places(_ id: CallID) -> Bool {
    switch action {
    case .start(let outgoing): outgoing.id == id
    case .join(let joined): joined == id
    default: false
    }
  }

  func receive(_ event: CallEvent) {
    guard !isFinished, isCarriedOut(by: event) else { return }
    switch event {
    case .ended(let call):
      if case .ended(.failed) = call.status {
        failure =
          failure
          ?? CommandError(
            code: .conversation,
            message: "The conversation failed before the SDK carried out the request")
      }
    case .joinFailed:
      failure =
        failure
        ?? CommandError(
          code: .conversation, message: "The conversation could not be joined")
    default:
      break
    }
    finish()
  }

  /// Whether the event carries out the request. The SDK performs a start once the app placed the
  /// call and its media is prepared; the start it performs is matched by its call.
  private func isCarriedOut(by event: CallEvent) -> Bool {
    switch event {
    case .performed(.start(let started), _):
      if case .start(let outgoing) = action { outgoing.id == started.id } else { false }
    case .performed(let performed, _): performed == action
    case .ended(let call), .previewStarted(let call), .joinFailed(let call, _):
      call.id == action.callID
    case .presented, .startRequested, .joinRequested, .audioActivated, .audioDeactivated,
      .audioInterrupted, .mediaServicesReset:
      false
    }
  }

  private func finish() {
    guard !isFinished else { return }
    isFinished = true
    expiry?.cancel()
    expiry = nil
    continuation?.resume()
    continuation = nil
  }

  private func expire() {
    guard !isFinished else { return }
    failure = CommandError(
      code: .deadlineExceeded, message: "The SDK didn't carry out the request in time")
    finish()
  }

  func wait() async throws(CommandError) {
    if !isFinished {
      await withCheckedContinuation { continuation in
        self.continuation = continuation
        expiry = Task { [weak self, clock, limit] in
          do { try await clock.sleep(for: limit) } catch { return }
          self?.expire()
        }
      }
    }
    if let failure { throw failure }
  }
}
