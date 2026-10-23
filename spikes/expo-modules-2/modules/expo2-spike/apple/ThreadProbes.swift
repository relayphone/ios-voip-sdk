import Darwin
import Dispatch
import Foundation
import ExpoModulesCore

@Record struct ThreadSample: Sendable {
  let phase: String
  let threadID: String
  let threadName: String
  let queueLabel: String
  let isMainThread: Bool
  let isOnJavaScriptThread: Bool
  let supportsAsyncScheduling: Bool
}

// Synchronous: Foundation's Thread.current is unavailable directly in async code.
nonisolated func captureThread(_ phase: String, runtime: JavaScriptRuntime) -> ThreadSample {
  var identifier: UInt64 = 0
  let status = pthread_threadid_np(nil, &identifier)
  return ThreadSample(
    phase: phase, threadID: status == 0 ? String(identifier) : "error:\(status)",
    threadName: Thread.current.name ?? "", queueLabel: String(cString: __dispatch_queue_get_label(nil)),
    isMainThread: Thread.isMainThread, isOnJavaScriptThread: runtime.isOnJavaScriptThread(),
    supportsAsyncScheduling: runtime.supportsAsyncScheduling)
}

@globalActor actor SDKActor { static let shared = SDKActor() }

@Record struct SDKReply: Sendable {
  let sequence: Int
  let threads: [ThreadSample]
}

@SDKActor enum SDKCommands {
  private static var sequence = 0
  static func probe(_ runtime: JavaScriptRuntime) async throws -> SDKReply {
    sequence += 1
    let current = sequence
    let before = captureThread("sdk-before-await", runtime: runtime)
    try await Task.sleep(for: .milliseconds(20))
    return SDKReply(sequence: current, threads: [before, captureThread("sdk-after-await", runtime: runtime)])
  }
}
