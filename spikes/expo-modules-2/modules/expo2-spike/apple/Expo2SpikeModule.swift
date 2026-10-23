import ExpoModulesCore
import Foundation

@ExpoModule("Expo2Spike")
public final class Expo2SpikeModule: Module {
  @JavaScriptActor private var version = 0
  @JavaScriptActor private var cached: CachedSnapshot?
  @JavaScriptActor private var freezer: JavaScriptFunction.Ref?
  @JavaScriptActor private var flushScheduled = false

  @Event var onChange: (ChangeEvent) -> Void

  @JS var snapshot: CachedSnapshot {
    get throws {
      if let cached { return cached }
      let initial = try makeSnapshot(0)
      cached = initial
      return initial
    }
  }

  @JS func publish(_ revision: Int) throws {
    guard revision > version else { return }
    let next = try makeSnapshot(revision)
    cached = next
    version = revision
    guard !flushScheduled else { return }
    flushScheduled = true
    let runtime = try appContext!.runtime
    runtime.schedule { [weak self] in
      guard let self, let cached = self.cached else { return }
      self.flushScheduled = false
      self.onChange(ChangeEvent(snapshot: cached, version: self.version))
    }
  }

  // Two scheduler turns drain the queued flush and its asynchronous event dispatch.
  @JS func drainChanges() async throws {
    let runtime = try appContext!.runtime
    await withCheckedContinuation { continuation in
      runtime.schedule { runtime.schedule { continuation.resume() } }
    }
  }

  @JS func writeResults(_ json: String) async throws {
    try await Task.detached {
      let directory = try FileManager.default.url(
        for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      try Data(json.utf8).write(to: directory.appendingPathComponent("expo2-results.json"), options: .atomic)
    }.value
  }

  @JavaScriptActor private func makeSnapshot(_ revision: Int) throws -> CachedSnapshot {
    let runtime = try appContext!.runtime
    precondition(runtime.isOnJavaScriptThread() && runtime.supportsAsyncScheduling)
    if freezer == nil {
      freezer = try runtime.eval("""
        (function freeze(value) {
          if (value && typeof value === 'object' && !Object.isFrozen(value)) {
            Object.values(value).forEach(freeze);
            Object.freeze(value);
          }
          return value;
        })
        """).asFunction().ref()
    }
    let record = SnapshotRecord(version: revision, conversations: [
      .ringing(RingingConversation(id: "ring-1", status: .ringing, caller: "Ada")),
      .active(ActiveConversation(id: "active-1", status: .active, connectedAt: 123)),
    ])
    let encoded = try SnapshotRecord.encode(record, in: runtime).ref()
    let frozen = try freezer!.withUnwrappedValue {
      try $0.call(arguments: JavaScriptValuesBuffer.copying(in: runtime, values: [encoded]))
    } ?? .undefined()
    return CachedSnapshot(value: frozen.ref())
  }
}
