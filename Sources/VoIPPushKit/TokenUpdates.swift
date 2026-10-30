import Foundation
import Synchronization

/// The VoIP push token, and the streams that follow it.
final class TokenUpdates: Sendable {
  private struct State {
    var token: Data?
    var continuations: [Int: AsyncStream<Data?>.Continuation] = [:]
    var nextKey = 0
  }

  private let state = Mutex(State())

  /// Returns a stream that starts with the current token, when there is one, then yields each
  /// change.
  func stream() -> AsyncStream<Data?> {
    let (stream, continuation) = AsyncStream.makeStream(of: Data?.self)
    let key = state.withLock { state in
      defer { state.nextKey += 1 }
      state.continuations[state.nextKey] = continuation
      if let token = state.token { continuation.yield(token) }
      return state.nextKey
    }
    continuation.onTermination = { [weak self] _ in
      _ = self?.state.withLock { $0.continuations.removeValue(forKey: key) }
    }
    return stream
  }

  /// Records a new token, or `nil` when the token was invalidated, and tells every stream.
  func send(_ token: Data?) {
    state.withLock { state in
      guard token != state.token else { return }
      state.token = token
      for continuation in state.continuations.values { continuation.yield(token) }
    }
  }
}
