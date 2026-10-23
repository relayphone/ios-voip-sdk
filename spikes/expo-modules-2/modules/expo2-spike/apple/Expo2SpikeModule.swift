import ExpoModulesCore
import Foundation
import Dispatch

@ExpoModule("Expo2Spike")
public final class Expo2SpikeModule: Module {
  @JavaScriptActor private var version = 0
  @JavaScriptActor private var fixtureSize = 2
  @JavaScriptActor private var cached: CachedSnapshot?
  @JavaScriptActor private var freezer: JavaScriptFunction.Ref?
  @JavaScriptActor private var flushScheduled = false

  @Event var onChange: (ChangeEvent) -> Void
  @Event var onBackground: (ThreadSample) -> Void

  @JS func threadSample(_ phase: String) throws -> ThreadSample {
    captureThread(phase, runtime: try appContext!.runtime)
  }

  @JS func defaultProbe() async throws -> [ThreadSample] {
    let runtime = try appContext!.runtime
    let before = captureThread("default-before-await", runtime: runtime)
    try await Task.sleep(for: .milliseconds(20))
    return [before, captureThread("default-after-await", runtime: runtime)]
  }

  // Only Sendable values cross into the SDK actor; the module stays in its binding context.
  @JS func sdkProbe() async throws -> SDKReply {
    let runtime = try appContext!.runtime
    return try await SDKCommands.probe(runtime)
  }

  @JS func emitFromBackground() throws {
    let context = appContext!
    let runtime = try context.runtime
    let name = Self._jsName
    let identity = ObjectIdentifier(self)
    DispatchQueue(label: "expo2.spike.background-event").async {
      guard let emitter = context.moduleRegistry.get(moduleWithName: name) as? Expo2SpikeModule,
        ObjectIdentifier(emitter) == identity else { return }
      emitter.onBackground(captureThread("background-emission", runtime: runtime))
    }
  }

  @JS func configureFixture(_ count: Int) throws {
    guard (2...4096).contains(count) else { throw NSError(domain: "Expo2Spike", code: 1) }
    fixtureSize = count
    try publish(version + 1)
  }

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
    let conversations: [ConversationValue] = (0..<fixtureSize).map { index in
      if index.isMultiple(of: 2) {
        return .ringing(RingingConversation(id: "ring-\(index / 2 + 1)", status: .ringing, caller: "Ada"))
      }
      return .active(ActiveConversation(id: "active-\(index / 2 + 1)", status: .active, connectedAt: 123))
    }
    let record = SnapshotRecord(version: revision, conversations: conversations)
    let encoded = try SnapshotRecord.encode(record, in: runtime).ref()
    let frozen = try freezer!.withUnwrappedValue {
      try $0.call(arguments: JavaScriptValuesBuffer.copying(in: runtime, values: [encoded]))
    } ?? .undefined()
    return CachedSnapshot(value: frozen.ref())
  }
}
