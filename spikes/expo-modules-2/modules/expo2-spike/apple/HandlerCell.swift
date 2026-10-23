import os

// Owns the single native waiter; neither timeout nor reload awaits an Expo Promise.
final class HandlerCell<Value: Sendable>: Sendable {
  private struct State: Sendable {
    var value: Value?
    var continuation: CheckedContinuation<Value, Never>?
    var created = 0
    var resumed = 0
  }
  private let state = OSAllocatedUnfairLock(initialState: State())
  var stats: [Int] { state.withLock { [$0.created, $0.resumed] } }
  func wait() async -> Value {
    await withCheckedContinuation { continuation in
      let ready = state.withLock { state -> Value? in
        precondition(state.created == 0, "Only one native caller per request")
        state.created = 1
        if let value = state.value { state.resumed += 1; return value }
        state.continuation = continuation
        return nil
      }
      if let ready { continuation.resume(returning: ready) }
    }
  }
  @discardableResult func finish(_ value: Value) -> Bool {
    let result = state.withLock { state -> (Bool, CheckedContinuation<Value, Never>?) in
      guard state.value == nil else { return (false, nil) }
      state.value = value
      let continuation = state.continuation
      state.continuation = nil
      if continuation != nil { state.resumed += 1 }
      return (true, continuation)
    }
    result.1?.resume(returning: value)
    return result.0
  }
}
