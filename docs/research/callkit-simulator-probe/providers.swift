import AVFoundation
import CallKit
import UIKit

// Several CXProviders in one process: which provider receives each action?
// PROBE_MODE=providers PROBE_PROVIDERS=<scenario>; one scenario per launch, then the app exits.

func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

private let tapQueueKey = DispatchSpecificKey<String>()

final class ProviderTap: NSObject, CXProviderDelegate, @unchecked Sendable {
  let label: String
  let queue: DispatchQueue
  private(set) var provider: CXProvider?
  unowned let sink: ProvidersProbe

  init(_ label: String, sink: ProvidersProbe) {
    self.label = label
    self.sink = sink
    queue = DispatchQueue(label: "probe.provider.\(label)")
    queue.setSpecific(key: tapQueueKey, value: label)
  }

  // Each provider gets a distinct, observable configuration.
  func make(handles: Set<CXHandle.HandleType> = [.phoneNumber, .generic], delegate: Bool = true) {
    let c = CXProviderConfiguration()
    c.supportsVideo = label == "A"
    c.maximumCallGroups = label == "A" ? 2 : 3
    c.maximumCallsPerCallGroup = label == "A" ? 1 : 2
    c.supportedHandleTypes = handles
    c.includesCallsInRecents = false
    provider = CXProvider(configuration: c)
    log("created", ["delegate": delegate, "handles": handles.map { $0.rawValue }.sorted(),
                    "groups": c.maximumCallGroups, "video": c.supportsVideo])
    if delegate { attach() }
  }
  func attach() { provider?.setDelegate(self, queue: queue); log("delegateSet") }
  func invalidate() { provider?.invalidate(); log("invalidated") }
  func drop() { provider = nil; log("dropped") }

  func log(_ event: String, _ fields: [String: Any] = [:]) {
    var f = fields
    f["p"] = label
    Trace.shared.log("tap." + event, f)
  }

  private func record(_ action: CXAction, _ provider: CXProvider, _ extra: [String: Any] = [:]) {
    var f = extra
    let kind = NSStringFromClass(type(of: action))
    f["kind"] = kind
    f["action"] = short(action.uuid)
    f["sameProvider"] = provider === self.provider
    f["onQueue"] = DispatchQueue.getSpecific(key: tapQueueKey) ?? "other"
    f["timeoutIn"] = (action.timeoutDate.timeIntervalSinceNow * 10).rounded() / 10
    if let call = action as? CXCallAction { f["call"] = short(call.callUUID) }
    log("perform", f)
    sink.note(label, kind, (action as? CXCallAction)?.callUUID)
  }

  func configureAudio() {
    try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [])
  }

  func providerDidBegin(_ provider: CXProvider) { log("didBegin", ["sameProvider": provider === self.provider]) }
  func providerDidReset(_ provider: CXProvider) { log("didReset", ["sameProvider": provider === self.provider]) }
  func provider(_ provider: CXProvider, execute transaction: CXTransaction) -> Bool {
    log("execute", ["tx": short(transaction.uuid), "actions": transaction.actions.map { short($0.uuid) }])
    return false
  }
  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    configureAudio()
    record(action, provider, ["handle": action.handle.value, "handleType": action.handle.type.rawValue])
    action.fulfill()
    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
    queue.asyncAfter(deadline: .now() + 0.3) { provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date()) }
  }
  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) { configureAudio(); record(action, provider); action.fulfill() }
  func provider(_ provider: CXProvider, perform action: CXEndCallAction) { record(action, provider); action.fulfill() }
  func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) { record(action, provider); action.fulfill() }
  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    record(action, provider, ["muted": action.isMuted])
    action.fulfill()
    log("fulfilled", ["action": short(action.uuid), "complete": action.isComplete])
  }
  func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) { record(action, provider); action.fulfill() }
  func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) { record(action, provider); action.fulfill() }
  func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
    log("timedOut", ["action": short(action.uuid), "kind": NSStringFromClass(type(of: action))])
  }
  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    log("didActivate", ["sameProvider": provider === self.provider])
  }
  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    log("didDeactivate", ["sameProvider": provider === self.provider])
  }
}

final class ProvidersProbe: @unchecked Sendable {
  let controller = CXCallController()
  let observer = CXCallObserver()
  private let lock = NSLock()
  private var notes: [(provider: String, kind: String, call: UUID?)] = []
  private var taps: [String: ProviderTap] = [:]

  func note(_ provider: String, _ kind: String, _ call: UUID?) {
    lock.lock(); defer { lock.unlock() }
    notes.append((provider, kind, call))
  }
  private func receivers(_ kind: String, _ call: UUID) -> [String] {
    lock.lock(); defer { lock.unlock() }
    return notes.filter { $0.kind == kind && $0.call == call }.map(\.provider)
  }
  func tap(_ label: String) -> ProviderTap {
    if let t = taps[label] { return t }
    let t = ProviderTap(label, sink: self)
    taps[label] = t
    return t
  }
  func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
  func snapshot(_ label: String) {
    Trace.shared.log("observer.snapshot", ["label": label, "calls": observer.calls.map(describe)])
  }

  // Requests one action and records which provider(s) received it.
  @discardableResult
  func route(_ action: CXCallAction, _ label: String) async -> [String] {
    let tx = CXTransaction(action: action)
    let kind = NSStringFromClass(type(of: action))
    Trace.shared.log("request", ["label": label, "tx": short(tx.uuid), "action": short(action.uuid),
                                 "kind": kind, "call": short(action.callUUID)])
    let result: String = await withCheckedContinuation { c in
      controller.request(tx) { err in c.resume(returning: describe(err)) }
    }
    var got: [String] = []
    if result == "ok" {
      let start = Date()
      while Date().timeIntervalSince(start) < 4, receivers(kind, action.callUUID).isEmpty { await sleep(0.05) }
      await sleep(0.5)  // catch a second receiver, if any
      got = receivers(kind, action.callUUID)
    }
    Trace.shared.log("route", ["label": label, "kind": kind, "call": short(action.callUUID), "result": result,
                               "receivers": got])
    return got
  }

  // A Focus on the test phone silences a first report; a repeat from the same number gets through.
  func ring(_ t: ProviderTap, _ label: String, number: String) async -> UUID? {
    guard let provider = t.provider else { return nil }
    for attempt in 1...3 {
      let id = UUID()
      let update = CXCallUpdate()
      update.remoteHandle = CXHandle(type: .phoneNumber, value: number)
      update.localizedCallerName = "Provider \(t.label)"
      update.supportsHolding = true
      let result: String = await withCheckedContinuation { c in
        provider.reportNewIncomingCall(with: id, update: update) { err in c.resume(returning: describe(err)) }
      }
      Trace.shared.log("report.incoming", ["label": label, "p": t.label, "attempt": attempt,
                                           "call": short(id), "result": result])
      if result == "ok" { return id }
      if !result.hasSuffix(":3") { return nil }  // only a Focus filter is worth retrying
      await sleep(1)
    }
    return nil
  }

  func outgoing(_ tag: String, handle: CXHandle = CXHandle(type: .phoneNumber, value: "+15555550150")) async {
    let x = UUID()
    let owners = await route(CXStartCallAction(call: x, handle: handle), "\(tag)-start")
    await sleep(1.5); snapshot("\(tag)-outgoing")
    if !owners.isEmpty { await route(CXSetMutedCallAction(call: x, muted: true), "\(tag)-mute") }
    await route(CXEndCallAction(call: x), "\(tag)-end")
    await sleep(1.5)
  }

  func incoming(_ t: ProviderTap, _ tag: String, number: String) async {
    guard let y = await ring(t, "\(tag)-incoming", number: number) else { return }
    await sleep(1.5); snapshot("\(tag)-ringing")
    await route(CXAnswerCallAction(call: y), "\(tag)-answer")
    await sleep(1.5)
    await route(CXSetMutedCallAction(call: y, muted: true), "\(tag)-mute")
    await route(CXEndCallAction(call: y), "\(tag)-end")
    await sleep(1.5)
  }

  func cleanup() async {
    for call in observer.calls where !call.hasEnded {
      await route(CXEndCallAction(call: call.uuid), "cleanup")
    }
    for t in taps.values { t.provider?.invalidate() }
  }

  func run() async {
    let scenario = ProcessInfo.processInfo.environment["PROBE_PROVIDERS"] ?? "ab"
    Trace.shared.log("providers.start", ["scenario": scenario, "os": UIDevice.current.systemVersion, "build": osBuild(),
                                         "simulator": ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "device",
                                         "injected": ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"]?.contains("CKSim") ?? false])
    let a = tap("A"), b = tap("B")
    switch scenario {
    case "single":
      a.make(); await sleep(1)
      await outgoing("single"); await incoming(a, "single-A", number: "+15555550160")
    case "ab", "ba":
      if scenario == "ab" { a.make(); await sleep(1); b.make() } else { b.make(); await sleep(1); a.make() }
      await sleep(1)
      await outgoing(scenario)
      await incoming(a, "\(scenario)-A", number: "+15555550161")
      await incoming(b, "\(scenario)-B", number: "+15555550162")
      await outgoing("\(scenario)-again")
    case "inv":
      a.make(); await sleep(1); b.make(); await sleep(1); b.invalidate(); await sleep(1)
      await outgoing("inv")
      await incoming(a, "inv-A", number: "+15555550163")
      _ = await ring(b, "inv-B-after-invalidate", number: "+15555550164")
    case "recreate":
      a.make(); await sleep(1); a.invalidate(); await sleep(1); b.make(); await sleep(1)
      await outgoing("recreate")
      await incoming(b, "recreate-B", number: "+15555550165")
    case "drop":
      a.make(); await sleep(1); b.make(); await sleep(1); b.drop(); await sleep(1)
      await outgoing("drop")
      await incoming(a, "drop-A", number: "+15555550166")
    case "late":
      a.make(); await sleep(1); b.make(delegate: false); await sleep(1)
      await outgoing("late-before-delegate")
      b.attach(); await sleep(1)
      await outgoing("late-after-delegate")
    case "handles":
      a.make(handles: [.phoneNumber]); await sleep(1); b.make(handles: [.emailAddress]); await sleep(1)
      await outgoing("handles-phone")
      await outgoing("handles-email", handle: CXHandle(type: .emailAddress, value: "probe@example.com"))
    default:
      Trace.shared.log("providers.unknownScenario", ["scenario": scenario])
    }
    await cleanup()
    await sleep(1); snapshot("final")
    Trace.shared.log("done")
    await sleep(0.5)
    exit(0)
  }
}
