import Synchronization

/// The streams of everyone who subscribed to a notifier's events.
///
/// CocoaPods builds every library into one module, so the name differs from the client's own.
final class NotifierEventStreams<Element: Sendable>: Sendable {
  private let continuations = Mutex<[Int: AsyncStream<Element>.Continuation]>([:])
  private let nextKey = Atomic(0)

  /// Returns a new stream of the elements yielded from now on.
  func stream() -> AsyncStream<Element> {
    let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
    let key = nextKey.add(1, ordering: .relaxed).oldValue
    continuations.withLock { $0[key] = continuation }
    continuation.onTermination = { [weak self] _ in
      _ = self?.continuations.withLock { $0.removeValue(forKey: key) }
    }
    return stream
  }

  /// Yields an element to every subscriber.
  func yield(_ element: Element) {
    for continuation in continuations.withLock({ Array($0.values) }) {
      continuation.yield(element)
    }
  }
}
