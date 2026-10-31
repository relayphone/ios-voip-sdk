#if SWIFT_PACKAGE
  public import VoIPCore
#endif

/// Media that records what the SDK asks of it and prepares calls as the test scripts.
@VoIPActor
public final class FakeMedia: CallMedia {
  /// Something the SDK asked of the media.
  public enum Record: Hashable, Sendable {
    /// The SDK asked to prepare a call's media.
    case prepare(Call)
    /// The SDK started audio.
    case activate
    /// The SDK stopped audio.
    case deactivate
  }

  /// How the fake prepares a call's media.
  public enum Preparation: Hashable, Sendable {
    /// Succeed at once.
    case succeed
    /// Fail at once.
    case fail
    /// Wait for ``finishPreparing(_:succeeded:)`` or for the SDK to cancel.
    case wait
  }

  /// The error the fake throws when preparing fails.
  public struct PreparationFailed: Error, Hashable, Sendable {}

  /// Everything the SDK asked of the media, in order.
  public private(set) var records: [Record] = []

  /// How the fake prepares each call's media. Defaults to ``Preparation/succeed``.
  public var preparation = Preparation.succeed

  private var waiting:
    [(id: UInt64, call: CallID, continuation: CheckedContinuation<Void, any Error>)] =
      []
  private var waitCount: UInt64 = 0

  /// Creates fake media that prepares every call at once.
  public nonisolated init() {}

  /// The calls whose media preparation is waiting, in the order they were asked for.
  public var waitingCalls: [CallID] { waiting.map(\.call) }

  /// Finishes the waiting preparations of a call's media.
  ///
  /// - Parameters:
  ///   - id: The call whose preparations to finish.
  ///   - succeeded: Whether preparing succeeded.
  public func finishPreparing(_ id: CallID, succeeded: Bool) {
    let finishing = waiting.filter { $0.call == id }
    waiting.removeAll { $0.call == id }
    for wait in finishing {
      if succeeded {
        wait.continuation.resume()
      } else {
        wait.continuation.resume(throwing: PreparationFailed())
      }
    }
  }

  // MARK: CallMedia

  /// Records the request, then prepares as ``preparation`` says.
  public func prepare(_ call: Call) async throws {
    records.append(.prepare(call))
    switch preparation {
    case .succeed:
      return
    case .fail:
      throw PreparationFailed()
    case .wait:
      waitCount += 1
      let id = waitCount
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, any Error>) in
          if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
          } else {
            waiting.append((id, call.id, continuation))
          }
        }
      } onCancel: { [weak self] in
        Task { @VoIPActor in self?.cancel(id) }
      }
    }
  }

  /// Records that audio started.
  public func activate() {
    records.append(.activate)
  }

  /// Records that audio stopped.
  public func deactivate() {
    records.append(.deactivate)
  }

  private func cancel(_ id: UInt64) {
    guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
    waiting.remove(at: index).continuation.resume(throwing: CancellationError())
  }
}
