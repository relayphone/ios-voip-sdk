import Synchronization

/// Values that any number of subscribers follow, each through its own stream.
final class Broadcast<Element: Sendable>: Sendable {
  private struct State {
    var continuations: [Int: AsyncStream<Element>.Continuation] = [:]
    var nextKey = 0
  }

  private let state = Mutex(State())

  /// Returns a new stream that starts with `current`, then yields each value sent from now on.
  func stream(startingWith current: [Element] = []) -> AsyncStream<Element> {
    let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
    let key = state.withLock { state in
      defer { state.nextKey += 1 }
      state.continuations[state.nextKey] = continuation
      for element in current { continuation.yield(element) }
      return state.nextKey
    }
    continuation.onTermination = { [weak self] _ in
      _ = self?.state.withLock { $0.continuations.removeValue(forKey: key) }
    }
    return stream
  }

  /// Sends a value to every stream.
  func send(_ element: Element) {
    state.withLock { state in
      for continuation in state.continuations.values { continuation.yield(element) }
    }
  }
}
