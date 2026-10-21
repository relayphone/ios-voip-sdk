import AVFoundation
import CallKit
import Darwin
import ObjectiveC
import PushKit
import SwiftUI

// Instrumented CallKit probe: runs one scripted scenario against the genuine
// CallKit framework and writes an ordered JSON trace to Documents/trace.jsonl.

final class Trace: @unchecked Sendable {
  static let shared = Trace()
  let t0 = DispatchTime.now().uptimeNanoseconds
  private let lock = NSLock()
  private var handle: FileHandle?
  init() {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let url = dir.appendingPathComponent("trace.jsonl")
    // Appends across launches so a cold launch from a push keeps earlier evidence.
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    handle = try? FileHandle(forWritingTo: url)
    _ = try? handle?.seekToEnd()
  }
  func log(_ event: String, _ fields: [String: Any] = [:]) {
    lock.lock(); defer { lock.unlock() }
    var f = fields
    f["event"] = event
    f["t_ms"] = Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
    f["main"] = Thread.isMainThread
    let data = (try? JSONSerialization.data(withJSONObject: f, options: [.sortedKeys])) ?? Data()
    handle?.write(data + Data("\n".utf8))
    FileHandle.standardError.write(Data("PROBE ".utf8) + data + Data("\n".utf8))
  }
}

func osBuild() -> String {
  var size = 0
  sysctlbyname("kern.osversion", nil, &size, nil, 0)
  var buffer = [CChar](repeating: 0, count: size)
  sysctlbyname("kern.osversion", &buffer, &size, nil, 0)
  return String(cString: buffer)
}

func describe(_ error: Error?) -> String {
  guard let error = error as NSError? else { return "ok" }
  return "\(error.domain):\(error.code)"
}

func describe(_ call: CXCall) -> [String: Any] {
  ["uuid": String(call.uuid.uuidString.prefix(8)), "outgoing": call.isOutgoing, "connected": call.hasConnected,
   "ended": call.hasEnded, "held": call.isOnHold]
}

func audioState() -> [String: Any] {
  let s = AVAudioSession.sharedInstance()
  return ["category": s.category.rawValue, "mode": s.mode.rawValue,
          "inputs": s.currentRoute.inputs.map { $0.portType.rawValue },
          "outputs": s.currentRoute.outputs.map { $0.portType.rawValue },
          "otherAudio": s.isOtherAudioPlaying, "sampleRate": s.sampleRate]
}

func methods(of name: String) -> [String] {
  guard let cls: AnyClass = NSClassFromString(name) else { return ["<missing>"] }
  var count: UInt32 = 0
  var out: [String] = []
  if let list = class_copyMethodList(cls, &count) {
    for i in 0..<Int(count) { out.append(NSStringFromSelector(method_getName(list[i]))) }
    free(list)
  }
  var ivarCount: UInt32 = 0
  if let ivars = class_copyIvarList(cls, &ivarCount) {
    for i in 0..<Int(ivarCount) { if let n = ivar_getName(ivars[i]) { out.append("ivar:" + String(cString: n)) } }
    free(ivars)
  }
  let sup = class_getSuperclass(cls).map { NSStringFromClass($0) } ?? "nil"
  return ["super:" + sup] + out.sorted()
}

enum Policy { case fulfill, fail, never, delay(Double) }

final class Probe: NSObject, CXProviderDelegate, CXCallObserverDelegate, PKPushRegistryDelegate, @unchecked Sendable {
  var registry: PKPushRegistry?
  func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
    Trace.shared.log("push.token", ["type": type.rawValue, "bytes": credentials.token.count])
    // Kept private: written to the app container, never logged.
    let hex = credentials.token.map { String(format: "%02x", $0) }.joined()
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    try? hex.write(to: dir.appendingPathComponent("voip-token.txt"), atomically: true, encoding: .utf8)
  }
  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) { Trace.shared.log("push.tokenInvalidated") }
  #if CKSIM_HAS_VOIP_METADATA
  @available(iOS 26.4, *)
  func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingVoIPPushWith payload: PKPushPayload,
                    metadata: PKVoIPPushMetadata, withCompletionHandler completion: @escaping () -> Void) {
    Trace.shared.log("push.received", ["api": "metadata", "mustReport": metadata.mustReport, "appState": UIApplication.shared.applicationState.rawValue, "pid": Int(getpid()), "keys": payload.dictionaryPayload.keys.map { "\($0)" }.sorted(),
                                       "payloadClass": NSStringFromClass(type(of: payload))])
    reportPush(payload, completion: completion)
  }
  #endif
  func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
    Trace.shared.log("push.received", ["api": "legacy"])
    reportPush(payload, completion: completion)
  }
  private func reportPush(_ payload: PKPushPayload, completion: @escaping () -> Void) {
    if ProcessInfo.processInfo.environment["PROBE_PUSH_REPORT"] == "none" || FileManager.default.fileExists(atPath: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("no-report").path) {
      Trace.shared.log("push.notReported"); completion(); return
    }
    let id = UUID()
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .phoneNumber, value: (payload.dictionaryPayload["from"] as? String) ?? "+15555550199")
    provider.reportNewIncomingCall(with: id, update: update) { err in
      Trace.shared.log("push.reported", ["result": describe(err)]); completion()
    }
  }
  func runPush() async {
    await sleep(Double(ProcessInfo.processInfo.environment["PROBE_PUSH_REGISTRATION_DELAY"] ?? "0") ?? 0)
    await MainActor.run { registerPushEarly() }
    await sleep(Double(ProcessInfo.processInfo.environment["PROBE_PUSH_WAIT"] ?? "12") ?? 12)
    snapshot("after-push-wait")
    for call in observer.calls where !call.hasEnded { _ = await request([CXEndCallAction(call: call.uuid)], label: "cleanup") }
    await sleep(1)
    snapshot("final")
    Trace.shared.log("done")
  }
  func registerPushEarly() {
    guard registry == nil else { return }
    let r = PKPushRegistry(queue: .main)
    r.delegate = self
    r.desiredPushTypes = [.voIP]
    registry = r
    Trace.shared.log("push.registered")
  }
  func runAPNsActive() async {
    await MainActor.run { registerPushEarly() }
    let id = UUID()
    _ = await request([CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: "APNs reference call"))], label: "apns-start")
    await sleep(2)
    snapshot("apns-active-ready")
    Trace.shared.log("apns.activeReady")
    await sleep(65)
    _ = await request([CXEndCallAction(call: id)], label: "apns-end")
    await sleep(1)
    snapshot("final")
    Trace.shared.log("done")
  }
  let provider: CXProvider
  let controller = CXCallController()
  let observer = CXCallObserver()
  var policy: [String: Policy] = [:]
  var answered: [CXAnswerCallAction] = []
  private let audioActivationLock = NSLock()
  private var callKitAudioActive = false

  override init() {
    let config = CXProviderConfiguration()
    config.supportsVideo = true
    config.maximumCallGroups = 2
    config.maximumCallsPerCallGroup = 2
    config.supportedHandleTypes = [.phoneNumber, .generic]
    config.includesCallsInRecents = false
    let opaque = (AVAudioSession.sharedInstance().value(forKey: "opaqueSessionID") as? NSNumber)?.uint32Value ?? 0
    let before = (config.value(forKey: "audioSessionID") as? NSNumber)?.intValue ?? -1
    if ProcessInfo.processInfo.environment["PROBE_AUDIO_SESSION_ID"] == "1" { config.setValue(NSNumber(value: opaque), forKey: "audioSessionID") }
    let after = (config.value(forKey: "audioSessionID") as? NSNumber)?.intValue ?? -1
    Trace.shared.log("audio.sessionID", ["opaque": Int(opaque), "configBefore": before, "configAfter": after])
    provider = CXProvider(configuration: config)
    super.init()
    provider.setDelegate(self, queue: nil)
    observer.setDelegate(self, queue: nil)
    let nc = NotificationCenter.default
    for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                 AVAudioSession.mediaServicesWereResetNotification, AVAudioSession.silenceSecondaryAudioHintNotification] {
      nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
        if note.name == AVAudioSession.mediaServicesWereResetNotification { self?.setCallKitAudioActive(false) }
        var f: [String: Any] = ["name": note.name.rawValue]
        if let info = note.userInfo { for (k, v) in info { f["\(k)"] = "\(v)" } }
        Trace.shared.log("audio.notification", f)
      }
    }
  }

  // MARK: provider delegate
  func providerDidBegin(_ provider: CXProvider) { Trace.shared.log("provider.didBegin") }
  func providerDidReset(_ provider: CXProvider) {
    setCallKitAudioActive(false)
    Trace.shared.log("provider.didReset")
  }
  func provider(_ provider: CXProvider, execute transaction: CXTransaction) -> Bool {
    Trace.shared.log("provider.executeTransaction", ["actions": transaction.actions.map { NSStringFromClass(type(of: $0)) },
      "transactionID": transaction.uuid.uuidString, "actionIDs": transaction.actions.map { String($0.uuid.uuidString.prefix(8)) }])
    return false
  }
  private func handle(_ action: CXAction, _ extra: [String: Any] = [:]) {
    let kind = NSStringFromClass(type(of: action))
    var f = extra
    f["kind"] = kind
    f["timeoutIn"] = (action.timeoutDate.timeIntervalSinceNow * 10).rounded() / 10
    let actionID = String(action.uuid.uuidString.prefix(8))
    f["id"] = actionID
    if let call = action as? CXCallAction { f["call"] = String(call.callUUID.uuidString.prefix(8)) }
    Trace.shared.log("provider.perform", f)
    switch policy[kind] ?? .fulfill {
    case .fulfill: action.fulfill(); Trace.shared.log("action.fulfilled", ["kind": kind, "id": actionID, "complete": action.isComplete])
    case .fail: action.fail(); Trace.shared.log("action.failed", ["kind": kind])
    case .never: Trace.shared.log("action.held", ["kind": kind, "id": actionID])
    case .delay(let s):
      DispatchQueue.main.asyncAfter(deadline: .now() + s) {
        action.fulfill(); Trace.shared.log("action.fulfilledLate", ["kind": kind, "complete": action.isComplete])
      }
    }
  }
  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    configureAudio("start")
    handle(action, ["handle": action.handle.value, "video": action.isVideo])
    provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
      Trace.shared.log("report.outgoingConnected")
    }
  }
  func configureAudio(_ label: String) {
    do {
      try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
      Trace.shared.log("audio.configured", ["label": label])
    } catch { Trace.shared.log("audio.configureFailed", ["label": label, "error": describe(error)]) }
  }
  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    configureAudio("answer"); answered.append(action); handle(action); answeredCalls.insert(action.callUUID)
  }
  func provider(_ provider: CXProvider, perform action: CXEndCallAction) { handle(action); endedCalls.insert(action.callUUID) }
  func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) { handle(action, ["onHold": action.isOnHold]) }
  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) { handle(action, ["muted": action.isMuted]) }
  func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
    handle(action, ["groupWith": action.callUUIDToGroupWith.map { String($0.uuidString.prefix(8)) } ?? "none"])
  }
  func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) { handle(action, ["digits": action.digits]) }
  func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
    Trace.shared.log("provider.timedOut", ["kind": NSStringFromClass(type(of: action)), "id": String(action.uuid.uuidString.prefix(8))])
  }
  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    setCallKitAudioActive(true)
    Trace.shared.log("provider.didActivateAudio", audioState())
  }
  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    setCallKitAudioActive(false)
    Trace.shared.log("provider.didDeactivateAudio", audioState())
  }

  // MARK: observer
  func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
    Trace.shared.log("observer.callChanged", describe(call))
  }

  // MARK: helpers
  func request(_ actions: [CXAction], label: String) async -> String {
    let transaction = CXTransaction(actions: actions)
    var fields: [String: Any] = ["label": label, "transactionID": transaction.uuid.uuidString,
                               "actionIDs": actions.map { String($0.uuid.uuidString.prefix(8)) }]
    if let group = actions.first as? CXSetGroupCallAction {
      fields["groupWith"] = group.callUUIDToGroupWith.map { String($0.uuidString.prefix(8)) } ?? "none"
    }
    Trace.shared.log("request.begin", fields)
    return await withCheckedContinuation { c in
      controller.request(transaction) { err in
        Trace.shared.log("request.completed", ["label": label, "result": describe(err)])
        c.resume(returning: describe(err))
      }
    }
  }
  var answeredCalls = Set<UUID>()
  var endedCalls = Set<UUID>()
  func reportIncoming(_ id: UUID, label: String, number: String = "+15555550100", name: String = "Probe Caller") async -> String {
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .phoneNumber, value: number)
    update.localizedCallerName = name
    update.supportsHolding = true
    update.supportsDTMF = true
    update.supportsGrouping = true
    update.supportsUngrouping = true
    update.hasVideo = false
    return await withCheckedContinuation { c in
      provider.reportNewIncomingCall(with: id, update: update) { err in
        Trace.shared.log("report.incomingCompleted", ["label": label, "result": describe(err)])
        c.resume(returning: describe(err))
      }
    }
  }
  func snapshot(_ label: String) {
    Trace.shared.log("observer.snapshot", ["label": label, "calls": observer.calls.map(describe),
                                           "pending": provider.pendingTransactions.count])
  }
  func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
  private func setCallKitAudioActive(_ active: Bool) {
    audioActivationLock.lock(); callKitAudioActive = active; audioActivationLock.unlock()
  }

  func micProbe(_ label: String, requireCallKitActivation: Bool = true) {
    audioActivationLock.lock(); let active = callKitAudioActive; audioActivationLock.unlock()
    // inputNode lazily opens hardware input. Normal calling probes must wait for
    // the audio handoff instead of opening it on the broken genuine simulator path.
    if requireCallKitActivation && !active {
      Trace.shared.log("mic.skipped", ["label": label, "reason": "callkit-inactive"]); return
    }
    // A device run must stay unattended: never trigger the microphone prompt.
    if AVAudioApplication.shared.recordPermission != .granted {
      Trace.shared.log("mic.skipped", ["label": label, "permission": AVAudioApplication.shared.recordPermission.rawValue]); return
    }
    Trace.shared.log("mic.begin", ["label": label, "callKitActive": active])
    let engine = AVAudioEngine()
    let input = engine.inputNode
    Trace.shared.log("mic.inputNodeReady", ["label": label])
    let format = input.outputFormat(forBus: 0)
    Trace.shared.log("mic.format", ["label": label, "rate": format.sampleRate, "channels": format.channelCount, "audio": audioState()])
    guard format.channelCount > 0, format.sampleRate > 0 else { Trace.shared.log("mic.noInput", ["label": label]); return }
    var frames = 0
    var peak: Float = 0
    let lock = NSLock()
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      lock.lock(); defer { lock.unlock() }
      frames += Int(buffer.frameLength)
      if let ch = buffer.floatChannelData?[0] {
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(ch[i])) }
      }
    }
    do { try engine.start() } catch { Trace.shared.log("mic.startFailed", ["label": label, "error": describe(error)]); return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      engine.stop(); input.removeTap(onBus: 0)
      lock.lock(); let f = frames; let p = peak; lock.unlock()
      Trace.shared.log("mic.result", ["label": label, "frames": f, "peak": p, "rate": format.sampleRate, "channels": format.channelCount])
    }
  }

  func manualActivation(_ label: String) -> Bool {
    do {
      try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [])
      try AVAudioSession.sharedInstance().setActive(true)
      Trace.shared.log("audio.manualActivated", ["label": label, "audio": audioState()])
      return true
    } catch {
      Trace.shared.log("audio.manualActivationFailed", ["label": label, "error": describe(error)])
      return false
    }
  }
  func runAudio() async {
    let c = UUID()
    _ = await request([CXStartCallAction(call: c, handle: CXHandle(type: .phoneNumber, value: "+15555550102"))], label: "start-audio")
    await sleep(3); snapshot("audio-connected")
    micProbe("system-only", requireCallKitActivation: false)
    await sleep(1.5)
    if manualActivation("fill-in") { micProbe("after-manual", requireCallKitActivation: false) }
    await sleep(1.5)
    _ = await request([CXEndCallAction(call: c)], label: "end-audio")
    await sleep(1)
    Trace.shared.log("done")
  }
  func runHooks() async {
    Hooks.install()
    let id = UUID()
    let answer = CXAnswerCallAction(call: id)
    Hooks.owned.insert(answer.uuid)
    // A Telnyx-style consumer: retain the concrete action, complete it later.
    provider(provider, perform: answer)
    await sleep(0.5)
    let end = CXEndCallAction(call: id)
    Hooks.owned.insert(end.uuid)
    provider(provider, perform: end)
    let start = CXStartCallAction(call: UUID(), handle: CXHandle(type: .generic, value: "x"))
    Hooks.owned.insert(start.uuid)
    start.fulfill(withDateStarted: Date())
    let mute = CXSetMutedCallAction(call: id, muted: true)
    Hooks.owned.insert(mute.uuid)
    mute.fail()
    await sleep(0.5)
    Trace.shared.log("done")
  }
  func runSuppress() async {
    let responds: (NSObject, String) -> Bool = { $0.responds(to: NSSelectorFromString($1)) }
    let probeUpdate = CXCallUpdate()
    let probeStart = CXStartCallAction(call: UUID(), handle: CXHandle(type: .generic, value: "x"))
    Trace.shared.log("suppress.support", ["update": responds(probeUpdate, "setShouldSuppressInCallUI:"),
      "start": responds(probeStart, "setShouldSuppressInCallUI:")])
    // Incoming with suppression requested on the update.
    let a = UUID()
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .phoneNumber, value: "+15555550100")
    if responds(update, "setShouldSuppressInCallUI:") { update.setValue(true, forKey: "shouldSuppressInCallUI") }
    let r: String = await withCheckedContinuation { c in
      provider.reportNewIncomingCall(with: a, update: update) { err in c.resume(returning: describe(err)) } }
    Trace.shared.log("suppress.incoming", ["result": r])
    await sleep(3); snapshot("suppress-ringing")
    _ = await request([CXAnswerCallAction(call: a)], label: "suppress-answer")
    await sleep(2); snapshot("suppress-answered")
    _ = await request([CXEndCallAction(call: a)], label: "suppress-end")
    await sleep(1)
    // Outgoing with suppression requested on the start action.
    let c = UUID()
    let start = CXStartCallAction(call: c, handle: CXHandle(type: .phoneNumber, value: "+15555550102"))
    if responds(start, "setShouldSuppressInCallUI:") { start.setValue(true, forKey: "shouldSuppressInCallUI") }
    _ = await request([start], label: "suppress-start")
    await sleep(3); snapshot("suppress-outgoing")
    _ = await request([CXEndCallAction(call: c)], label: "suppress-end-out")
    await sleep(1)
    Trace.shared.log("done")
  }
  func runSemantics() async {
    let sections = Set((ProcessInfo.processInfo.environment["PROBE_SECTIONS"] ?? "waiting,failures,starts,remote").split(separator: ",").map(String.init))
    if sections.contains("waiting") { await semWaiting() }
    if sections.contains("waiting2") { await semWaiting2() }
    if sections.contains("failures") { await semFailures() }
    if sections.contains("starts") { await semStarts() }
    if sections.contains("remote") { await semRemote() }
    snapshot("final")
    Trace.shared.log("done")
  }
  func semWaiting() async {
    // 1. Call waiting with separate and combined transactions.
    let a = UUID(), b = UUID()
    Trace.shared.log("step", ["name": "waiting", "a": String(a.uuidString.prefix(8)), "b": String(b.uuidString.prefix(8))])
    _ = await reportIncoming(a, label: "incoming-a")
    _ = await request([CXAnswerCallAction(call: a)], label: "answer-a")
    await sleep(1.5)
    _ = await reportIncoming(b, label: "incoming-b", number: "+15555550101")
    await sleep(1)
    _ = await request([CXSetHeldCallAction(call: a, onHold: true)], label: "hold-a")
    _ = await request([CXAnswerCallAction(call: b)], label: "answer-b")
    await sleep(2); snapshot("a-held-b-active")
    _ = await request([CXSetHeldCallAction(call: b, onHold: true), CXSetHeldCallAction(call: a, onHold: false)], label: "swap")
    await sleep(1.5); snapshot("swapped")
    _ = await request([CXSetHeldCallAction(call: b, onHold: false)], label: "unhold-b-both-active")
    await sleep(1); snapshot("unhold-b")
    _ = await request([CXSetGroupCallAction(call: b, callUUIDToGroupWith: a)], label: "merge")
    await sleep(1); snapshot("merged")
    _ = await request([CXSetGroupCallAction(call: b, callUUIDToGroupWith: nil)], label: "ungroup")
    await sleep(1); snapshot("ungrouped")
    _ = await request([CXEndCallAction(call: a), CXEndCallAction(call: b)], label: "end-both")
    await sleep(2); snapshot("ended")
  }
  func semWaiting2() async {
    let a = UUID(), b = UUID()
    Trace.shared.log("step", ["name": "hold-then-answer", "a": String(a.uuidString.prefix(8)), "b": String(b.uuidString.prefix(8))])
    _ = await reportIncoming(a, label: "incoming-a")
    _ = await request([CXAnswerCallAction(call: a)], label: "answer-a")
    await sleep(1.5)
    _ = await reportIncoming(b, label: "incoming-b", number: "+15555550101")
    _ = await request([CXSetHeldCallAction(call: a, onHold: true)], label: "hold-a")
    await sleep(1.5); snapshot("a-held")
    _ = await request([CXAnswerCallAction(call: b)], label: "answer-b-after-hold")
    await sleep(2); snapshot("b-answered")
    _ = await request([CXEndCallAction(call: a), CXEndCallAction(call: b)], label: "end-both")
    await sleep(2)
    let c = UUID(), d = UUID()
    Trace.shared.log("step", ["name": "end-and-accept", "c": String(c.uuidString.prefix(8)), "d": String(d.uuidString.prefix(8))])
    _ = await reportIncoming(c, label: "incoming-c")
    _ = await request([CXAnswerCallAction(call: c)], label: "answer-c")
    await sleep(1.5)
    _ = await reportIncoming(d, label: "incoming-d", number: "+15555550101")
    await sleep(1)
    _ = await request([CXEndCallAction(call: c), CXAnswerCallAction(call: d)], label: "end-c-answer-d")
    await sleep(2); snapshot("after-end-and-accept")
    _ = await request([CXEndCallAction(call: d)], label: "end-d")
    await sleep(1.5)
  }
  func semFailures() async {
    // 2. Action failures and missing completions.
    let c = UUID()
    Trace.shared.log("step", ["name": "answer-fails", "uuid": String(c.uuidString.prefix(8))])
    policy["CXAnswerCallAction"] = .fail
    _ = await reportIncoming(c, label: "incoming-c")
    _ = await request([CXAnswerCallAction(call: c)], label: "answer-c-fail")
    await sleep(2); snapshot("after-answer-fail")
    policy["CXAnswerCallAction"] = .fulfill
    _ = await request([CXEndCallAction(call: c)], label: "end-c")
    await sleep(1)
    let d = UUID()
    Trace.shared.log("step", ["name": "end-never", "uuid": String(d.uuidString.prefix(8))])
    _ = await reportIncoming(d, label: "incoming-d")
    _ = await request([CXAnswerCallAction(call: d)], label: "answer-d")
    await sleep(1)
    policy["CXEndCallAction"] = .never
    policy["CXSetMutedCallAction"] = .fail
    _ = await request([CXSetMutedCallAction(call: d, muted: true)], label: "mute-d-fail")
    await sleep(1); snapshot("after-mute-fail")
    _ = await request([CXEndCallAction(call: d)], label: "end-d-never")
    await sleep(8); snapshot("after-end-deadline")
    policy["CXEndCallAction"] = .fulfill
    policy["CXSetMutedCallAction"] = .fulfill
    provider.reportCall(with: d, endedAt: Date(), reason: .failed)
    await sleep(1.5); snapshot("after-report-end-d")
  }
  func semStarts() async {
    let e = UUID()
    Trace.shared.log("step", ["name": "start-fails", "uuid": String(e.uuidString.prefix(8))])
    policy["CXStartCallAction"] = .fail
    _ = await request([CXStartCallAction(call: e, handle: CXHandle(type: .phoneNumber, value: "+15555550102"))], label: "start-e-fail")
    await sleep(2); snapshot("after-start-fail")
    policy["CXStartCallAction"] = .fulfill
  }
  func semRemote() async {
    // 3. Remote end while ringing, with each reason.
    for (i, reason) in [CXCallEndedReason.remoteEnded, .unanswered, .answeredElsewhere, .declinedElsewhere].enumerated() {
      let r = UUID()
      _ = await reportIncoming(r, label: "ring-\(i)")
      await sleep(0.7)
      provider.reportCall(with: r, endedAt: Date(), reason: reason)
      Trace.shared.log("report.ended", ["label": "ring-\(i)", "reason": reason.rawValue])
      await sleep(1)
    }
  }
  func waitUntil(_ label: String, timeout: Double, _ condition: () -> Bool) async -> Bool {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
      if condition() { Trace.shared.log("wait.met", ["label": label, "after": Int(Date().timeIntervalSince(start) * 1000)]); return true }
      await sleep(0.1)
    }
    Trace.shared.log("wait.timeout", ["label": label]); return false
  }
  // Scripted calls for the XCUITest that operates the genuine system UI.
  func runUI() async {
    var task = UIBackgroundTaskIdentifier.invalid
    func keepAlive() {
      if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
      task = UIApplication.shared.beginBackgroundTask(withName: "probe") { Trace.shared.log("bgtask.expired") }
    }
    keepAlive()
    NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in Trace.shared.log("app.background") }
    NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in Trace.shared.log("app.foreground") }
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID(), f = UUID(), g = UUID()
    await sleep(3)
    Trace.shared.log("phase", ["name": "1-banner-accept"])
    _ = await reportIncoming(a, label: "A", name: "Alice Probe")
    _ = await waitUntil("A answered", timeout: 90) { answeredCalls.contains(a) }
    await sleep(5)
    Trace.shared.log("phase", ["name": "2-hold-and-accept"])
    _ = await reportIncoming(b, label: "B", number: "+15555550101", name: "Bob Probe")
    _ = await waitUntil("B answered", timeout: 90) { answeredCalls.contains(b) }
    await sleep(4); snapshot("after-hold-and-accept")
    _ = await request([CXEndCallAction(call: b)], label: "end-B")
    await sleep(1.5)
    _ = await request([CXSetHeldCallAction(call: a, onHold: false)], label: "unhold-A")
    await sleep(3); snapshot("after-unhold-A")
    Trace.shared.log("phase", ["name": "3-end-and-accept"])
    _ = await reportIncoming(c, label: "C", number: "+15555550102", name: "Carol Probe")
    _ = await waitUntil("C answered", timeout: 90) { answeredCalls.contains(c) }
    await sleep(4); snapshot("after-end-and-accept")
    Trace.shared.log("phase", ["name": "4-decline-waiting"])
    _ = await reportIncoming(d, label: "D", number: "+15555550103", name: "Dave Probe")
    _ = await waitUntil("D ended", timeout: 90) { endedCalls.contains(d) }
    await sleep(2); snapshot("after-decline")
    for call in observer.calls where !call.hasEnded {
      _ = await request([CXEndCallAction(call: call.uuid)], label: "cleanup")
    }
    keepAlive()
    Trace.shared.log("phase", ["name": "5-locked"])
    await sleep(12)
    _ = await reportIncoming(e, label: "E", number: "+15555550104", name: "Erin Probe")
    _ = await waitUntil("E answered", timeout: 90) { answeredCalls.contains(e) }
    _ = await waitUntil("E ended", timeout: 150) { endedCalls.contains(e) }
    await sleep(2); snapshot("after-locked-call")
    keepAlive()
    Trace.shared.log("phase", ["name": "6-background-banner"])
    await sleep(12)
    _ = await reportIncoming(f, label: "F", number: "+15555550105", name: "Fay Probe")
    _ = await waitUntil("F answered", timeout: 90) { answeredCalls.contains(f) }
    await sleep(5)
    _ = await request([CXEndCallAction(call: f)], label: "end-F")
    await sleep(3)
    keepAlive()
    Trace.shared.log("phase", ["name": "7-ring-timeout"])
    _ = await reportIncoming(g, label: "G", number: "+15555550106", name: "Gus Probe")
    _ = await waitUntil("G ended by system", timeout: 120) { endedCalls.contains(g) }
    await sleep(2); snapshot("final")
    Trace.shared.log("done")
  }
  func run() async {
    let env = ProcessInfo.processInfo.environment
    recordLaunch()
    if env["PROBE_MODE"] == "ui" { await runUI(); return }
    if env["PROBE_MODE"] == "apns-active" { await runAPNsActive(); return }
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    if env["PROBE_MODE"] == "push" || FileManager.default.fileExists(atPath: documents.appendingPathComponent("push-mode").path) { await runPush(); return }
    if env["PROBE_MODE"] == "semantics" { await runSemantics(); return }
    if env["PROBE_MODE"] == "suppress" { await runSuppress(); return }
    if env["PROBE_MODE"] == "audio" { await runAudio(); return }
    if env["PROBE_MODE"] == "hooks" { await runHooks(); return }
    Trace.shared.log("start", ["os": UIDevice.current.systemVersion, "model": UIDevice.current.model,
                               "simulator": env["SIMULATOR_DEVICE_NAME"] ?? "device", "build": osBuild(), "audio": audioState()])
    for cls in ["CXAction", "CXCallAction", "CXAnswerCallAction", "CXTransaction", "CXProvider", "CXCallController",
                "CXCallObserver", "CXCall", "CXProviderConfiguration"] {
      Trace.shared.log("introspect", ["class": cls, "members": methods(of: cls)])
    }
    // A standalone action, never submitted: what does completing it do?
    let loose = CXAnswerCallAction(call: UUID())
    Trace.shared.log("loose.created", ["complete": loose.isComplete, "timeoutIn": loose.timeoutDate.timeIntervalSinceNow])
    loose.fulfill()
    Trace.shared.log("loose.fulfilled", ["complete": loose.isComplete])
    snapshot("initial")

    // 1. Incoming call, answered by the app's own controller.
    let a = UUID()
    Trace.shared.log("step", ["name": "incoming", "uuid": String(a.uuidString.prefix(8))])
    _ = await reportIncoming(a, label: "incoming-a")
    _ = await reportIncoming(a, label: "incoming-a-duplicate")
    await sleep(2)
    if env["PROBE_WAIT_FOR_TEARDOWN"] == "1" {
      // A cold simulator may stall UI-host lookup. Observe its teardown rather
      // than racing it with a fixed two-second answer request.
      _ = await waitUntil("genuine incoming torn down", timeout: 30) {
        self.observer.calls.allSatisfy { $0.uuid != a || $0.hasEnded }
      }
    }
    snapshot("ringing")
    _ = await request([CXAnswerCallAction(call: a)], label: "answer-a")
    await sleep(2.5); snapshot("answered")
    micProbe("after-answer")
    await sleep(1.5)
    _ = await request([CXSetMutedCallAction(call: a, muted: true)], label: "mute-a")
    _ = await request([CXPlayDTMFCallAction(call: a, digits: "12#", type: .singleTone)], label: "dtmf-a")
    _ = await request([CXSetHeldCallAction(call: a, onHold: true)], label: "hold-a")
    await sleep(1); snapshot("held")
    _ = await request([CXSetHeldCallAction(call: a, onHold: false)], label: "unhold-a")

    // 2. Second incoming while the first is active: call waiting.
    let b = UUID()
    Trace.shared.log("step", ["name": "call-waiting", "uuid": String(b.uuidString.prefix(8))])
    _ = await reportIncoming(b, label: "incoming-b", number: "+15555550101")
    await sleep(1)
    _ = await request([CXSetHeldCallAction(call: a, onHold: true), CXAnswerCallAction(call: b)], label: "hold-a-answer-b")
    await sleep(1.5); snapshot("two-calls")
    _ = await request([CXSetGroupCallAction(call: a, callUUIDToGroupWith: b)], label: "merge-a-b")
    await sleep(1); snapshot("merged")
    _ = await request([CXEndCallAction(call: b)], label: "end-b")
    provider.reportCall(with: a, endedAt: Date(), reason: .remoteEnded)
    Trace.shared.log("report.ended", ["label": "remote-end-a"])
    await sleep(2); snapshot("after-end")

    // 3. Outgoing call.
    let c = UUID()
    Trace.shared.log("step", ["name": "outgoing", "uuid": String(c.uuidString.prefix(8))])
    _ = await request([CXStartCallAction(call: c, handle: CXHandle(type: .phoneNumber, value: "+15555550102"))], label: "start-c")
    await sleep(2.5); snapshot("outgoing")
    micProbe("after-outgoing")
    await sleep(1.5)
    _ = await request([CXEndCallAction(call: c)], label: "end-c")
    await sleep(1.5)

    // 4. Error contracts.
    Trace.shared.log("step", ["name": "errors"])
    _ = await request([CXAnswerCallAction(call: UUID())], label: "answer-unknown")
    _ = await request([CXEndCallAction(call: UUID())], label: "end-unknown")
    _ = await request([], label: "empty-transaction")

    // 5. Answer action that is never completed: measure the deadline.
    let d = UUID()
    Trace.shared.log("step", ["name": "answer-timeout", "uuid": String(d.uuidString.prefix(8))])
    policy["CXAnswerCallAction"] = .never
    _ = await reportIncoming(d, label: "incoming-d")
    await sleep(0.5)
    _ = await request([CXAnswerCallAction(call: d)], label: "answer-d-never")
    await sleep(Double(env["PROBE_TIMEOUT_WAIT"] ?? "12") ?? 12)
    snapshot("after-timeout-wait")
    if let held = answered.last { held.fulfill(); Trace.shared.log("late.fulfill", ["id": String(held.uuid.uuidString.prefix(8)), "complete": held.isComplete]) }
    await sleep(1); snapshot("after-late-fulfill")
    policy["CXAnswerCallAction"] = .fulfill
    provider.reportCall(with: d, endedAt: Date(), reason: .failed)
    await sleep(1)

    // 6. Unanswered incoming call: does the system ever end it on its own?
    let e = UUID()
    Trace.shared.log("step", ["name": "unanswered", "uuid": String(e.uuidString.prefix(8))])
    _ = await reportIncoming(e, label: "incoming-e")
    await sleep(Double(env["PROBE_RING_WAIT"] ?? "8") ?? 8)
    snapshot("unanswered-wait")
    _ = await request([CXEndCallAction(call: e)], label: "decline-e")
    await sleep(1.5); snapshot("final")
    provider.invalidate()
    Trace.shared.log("provider.invalidated")
    await sleep(1)
    Trace.shared.log("done")
  }
}

// Test-only completion interception for runtime-owned actions.
enum Hooks {
  nonisolated(unsafe) static var owned = Set<UUID>()
  static func swap(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
    guard let m1 = class_getInstanceMethod(cls, original), let m2 = class_getInstanceMethod(HookTarget.self, replacement) else {
      Trace.shared.log("hook.missing", ["class": NSStringFromClass(cls), "selector": NSStringFromSelector(original)]); return
    }
    // Add the replacement under the original's class so the exchange is local to it.
    class_addMethod(cls, replacement, method_getImplementation(m2), method_getTypeEncoding(m2))
    if let added = class_getInstanceMethod(cls, replacement) { method_exchangeImplementations(class_getInstanceMethod(cls, original)!, added) }
    _ = m1
  }
  static func install() {
    swap(CXAction.self, #selector(CXAction.fulfill), #selector(HookTarget.ck_fulfill))
    swap(CXAction.self, #selector(CXAction.fail), #selector(HookTarget.ck_fail))
    swap(CXAnswerCallAction.self, #selector(CXAnswerCallAction.fulfill(withDateConnected:)), #selector(HookTarget.ck_fulfillDate(_:)))
    swap(CXStartCallAction.self, #selector(CXStartCallAction.fulfill(withDateStarted:)), #selector(HookTarget.ck_fulfillDate(_:)))
    swap(CXEndCallAction.self, #selector(CXEndCallAction.fulfill(withDateEnded:)), #selector(HookTarget.ck_fulfillDate(_:)))
    Trace.shared.log("hooks.installed")
  }
}
final class HookTarget: NSObject {
  @objc func ck_fulfill() {
    let a = unsafeBitCast(self, to: CXAction.self)
    if Hooks.owned.contains(a.uuid) { Trace.shared.log("hook.fulfill", ["kind": NSStringFromClass(type(of: a))]); return }
    ck_fulfill()
  }
  @objc func ck_fail() {
    let a = unsafeBitCast(self, to: CXAction.self)
    if Hooks.owned.contains(a.uuid) { Trace.shared.log("hook.fail", ["kind": NSStringFromClass(type(of: a))]); return }
    ck_fail()
  }
  @objc func ck_fulfillDate(_ date: Date) {
    let a = unsafeBitCast(self, to: CXAction.self)
    if Hooks.owned.contains(a.uuid) { Trace.shared.log("hook.fulfillWithDate", ["kind": NSStringFromClass(type(of: a))]); return }
    ck_fulfillDate(date)
  }
}

func recordLaunch() {
  let env = ProcessInfo.processInfo.environment
  let status = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CKSimRuntimeIsActive")
  let injected = status.map { unsafeBitCast($0, to: (@convention(c) () -> Bool).self)() } ?? false
  let versionSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CKSimRuntimeVersion")
  let runtimeVersion = versionSymbol.map { String(cString: unsafeBitCast($0, to: (@convention(c) () -> UnsafePointer<CChar>).self)()) } ?? "discovery-spike"
  Trace.shared.log("launch", ["pid": Int(getpid()), "appState": UIApplication.shared.applicationState.rawValue,
                "injected": injected, "traceVersion": 2, "mode": env["PROBE_MODE"] ?? "default",
                "runID": env["CKSIM_RUN_ID"] ?? "manual", "simulatorID": env["SIMULATOR_UDID"] ?? "device",
                "bundleID": Bundle.main.bundleIdentifier ?? "unknown"])
  Trace.shared.log("runtime.identity", ["version": runtimeVersion])
}

@main
struct ProbeApp: App {
  init() {
    Trace.shared.log("app.entry")
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    if FileManager.default.fileExists(atPath: documents.appendingPathComponent("push-mode").path) {
      ProbeApp.probe.registerPushEarly()
    }
  }
  @State private var started = false
  static let probe = Probe()
  var body: some Scene {
    WindowGroup {
      Text("CallKit probe").task {
        guard !started else { return }
        started = true
        #if CKSIM_CONFORMANCE
        if ProcessInfo.processInfo.environment["PROBE_MODE"] == "report-threading" {
          recordLaunch()
          await ReportThreadingProbe().run()
          return
        }
        if ProcessInfo.processInfo.environment["PROBE_MODE"] == "generations" {
          recordLaunch()
          await GenerationProbe().run()
          return
        }
        if ProcessInfo.processInfo.environment["PROBE_MODE"] == "providers" {
          recordLaunch()
          await ProvidersProbe().run()
          return
        }
        #endif
        await ProbeApp.probe.run()
      }
    }
  }
}
