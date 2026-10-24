import AVFoundation
import LiveCommunicationKit
import UIKit

// LiveCommunicationKit-only multi-call probe. No CXProvider is ever created here (D13).
// Configured by Documents/lck-multi.json (a file without "row" and "steps" leaves it off):
//   {"row": "hold-accept", "groups": 2, "perGroup": 1, "capabilities": ["pausing", "merging", "unmerging"],
//    "fulfill": {"Pause": {"mode": "delay", "ms": 2000}, "Join": {"mode": "fail", "nth": 2}},
//    "steps": [{"op": "incoming", "id": "A"}, {"op": "waitState", "id": "A", "state": "joined"}, ...]}
// Fulfillment modes per action kind: immediate, delay (ms), fail, pending (until expiry) and reverse
// (actions arriving within reverseWindowMs settle in reverse delivery order). "nth" limits a rule to
// that occurrence of the kind. The genuine system UI is driven separately by MultiCallUITests.

struct FulfillRule: Codable { var mode: String; var ms: Int?; var nth: Int? }

struct MultiStep: Codable {
  var op: String
  var id: String?, other: String?, handle: String?, name: String?, state: String?, kind: String?, label: String?
  var s: Double?, timeout: Double?, count: Int?
  var paused: Bool?, video: Bool?
  var capabilities: [String]?
}

struct LCKMultiConfig: Codable {
  var row: String
  var steps: [MultiStep]
  var groups: Int?, perGroup: Int?
  var capabilities: [String]?
  var fulfill: [String: FulfillRule]?
  var reverseWindowMs: Int?, connectAfterMs: Int?
  var maxSeconds: Double?
  static func load() -> LCKMultiConfig? {
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("lck-multi.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(LCKMultiConfig.self, from: data)
  }
}

func capabilities(_ names: [String]?) -> Conversation.Capabilities {
  var caps: Conversation.Capabilities = []
  for name in names ?? [] {
    switch name {
    case "pausing": caps.insert(.pausing)
    case "merging": caps.insert(.merging)
    case "unmerging": caps.insert(.unmerging)
    case "video": caps.insert(.video)
    case "playingTones": caps.insert(.playingTones)
    default: break
    }
  }
  return caps
}

final class LCKMultiProbe: NSObject, ConversationManagerDelegate, @unchecked Sendable {
  static var shared: LCKMultiProbe?
  let config: LCKMultiConfig
  let manager: ConversationManager
  private let lock = NSLock()
  private var ids: [String: UUID] = [:]
  private var names: [UUID: String] = [:]
  private var delivered: [UUID: Date] = [:]
  private var kindCounts: [String: Int] = [:]
  private var reverseBuffer: [ConversationAction] = []
  private var status = "starting"
  private var finished = false

  static func startIfConfigured() {
    guard shared == nil, LCKPushProbe.shared == nil, let config = LCKMultiConfig.load() else { return }
    shared = LCKMultiProbe(config: config)
  }

  var currentStatus: String { lock.lock(); defer { lock.unlock() }; return status }

  init(config: LCKMultiConfig) {
    self.config = config
    let c = ConversationManager.Configuration(
      ringtoneName: nil, iconTemplateImageData: nil, maximumConversationGroups: config.groups ?? 2,
      maximumConversationsPerConversationGroup: config.perGroup ?? 1, includesConversationInRecents: false,
      supportsVideo: false, supportedHandleTypes: [.phoneNumber, .generic])
    manager = ConversationManager(configuration: c)
    super.init()
    manager.delegate = self
    UIApplication.shared.isIdleTimerDisabled = true
    log("launch", ["pid": Int(getpid()), "appState": UIApplication.shared.applicationState.rawValue,
                   "os": UIDevice.current.systemVersion, "build": osBuild(), "groups": c.maximumConversationGroups,
                   "perGroup": c.maximumConversationsPerConversationGroup,
                   "capabilities": config.capabilities ?? ["pausing", "merging", "unmerging"],
                   "fulfill": (config.fulfill ?? [:]).mapValues { "\($0.mode)/\($0.ms ?? 0)/\($0.nth ?? 0)" }])
    Task { @MainActor in await self.runScript() }
    let limit = config.maxSeconds ?? 240
    DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [self] in
      guard !isFinished else { return }
      log("watchdog", ["seconds": limit]); endAll(); setStatus("DONE watchdog")
    }
  }

  private var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
  private func setStatus(_ s: String) {
    lock.lock(); status = s; if s.hasPrefix("DONE") { finished = true }; lock.unlock()
    log("status", ["status": s])
  }

  // Every row carries monotonic (device uptime) and wall-clock milliseconds alongside the Trace offset.
  func log(_ event: String, _ fields: [String: Any] = [:]) {
    var f = fields
    f["row"] = config.row
    f["mono_ms"] = (ProcessInfo.processInfo.systemUptime * 1000).rounded()
    f["wall_ms"] = (Date().timeIntervalSince1970 * 1000).rounded()
    Trace.shared.log("lckmulti." + event, f)
  }

  private func name(_ id: UUID) -> String { lock.lock(); defer { lock.unlock() }; return names[id] ?? "?" }
  private func uuid(_ key: String?) -> UUID? { lock.lock(); defer { lock.unlock() }; return key.flatMap { ids[$0] } }
  private func conversation(_ key: String?) -> Conversation? {
    guard let id = uuid(key) else { return nil }
    return manager.conversations.first { $0.uuid == id }
  }

  static func kind(_ action: ConversationAction) -> String {
    switch action {
    case is JoinConversationAction: "Join"
    case is StartConversationAction: "Start"
    case is EndConversationAction: "End"
    case is PauseConversationAction: "Pause"
    case is MergeConversationAction: "Merge"
    case is UnmergeConversationAction: "Unmerge"
    case is MuteConversationAction: "Mute"
    case is PlayToneAction: "PlayTone"
    default: "\(type(of: action))"
    }
  }

  func describe(_ action: ConversationAction) -> [String: Any] {
    var f: [String: Any] = ["kind": Self.kind(action), "action": action.uuid.uuidString,
                            "conversation": action.conversationUUID.uuidString, "conv": name(action.conversationUUID),
                            "timeoutIn": (action.timeoutDate.timeIntervalSinceNow * 1000).rounded(),
                            "timeoutWall_ms": (action.timeoutDate.timeIntervalSince1970 * 1000).rounded(),
                            "actionState": "\(action.state)"]
    if let a = action as? PauseConversationAction { f["isPaused"] = a.isPaused }
    if let a = action as? MuteConversationAction { f["isMuted"] = a.isMuted }
    if let a = action as? MergeConversationAction {
      f["mergeWith"] = a.conversationUUIDToMergeWith.uuidString; f["mergeWithConv"] = name(a.conversationUUIDToMergeWith)
    }
    if let a = action as? StartConversationAction { f["handles"] = a.handles.map(\.value); f["isVideo"] = a.isVideo }
    return f
  }

  func snapshot(_ label: String) {
    let conversations: [[String: Any]] = manager.conversations.map { c in
      ["conv": name(c.uuid), "uuid": c.uuid.uuidString, "state": "\(c.state)", "local": c.localMember?.value ?? "",
       "debug": String(c.debugDescription.prefix(600))]
    }
    log("snapshot", ["label": label, "conversations": conversations, "pending": manager.pendingActions.map(describe),
                     "audio": audioState()])
  }

  // MARK: Script

  @MainActor func runScript() async {
    try? await Task.sleep(for: .milliseconds(1500))
    for (index, step) in config.steps.enumerated() {
      setStatus("step \(index) \(step.op) \(step.id ?? "")")
      let started = Date()
      log("step", ["index": index, "op": step.op, "id": step.id ?? "", "other": step.other ?? ""])
      await run(step)
      log("stepDone", ["index": index, "op": step.op, "ms": Int(Date().timeIntervalSince(started) * 1000)])
    }
    snapshot("end")
    endAll()
    try? await Task.sleep(for: .seconds(2))
    snapshot("final")
    setStatus("DONE")
  }

  @MainActor private func run(_ step: MultiStep) async {
    switch step.op {
    case "incoming":
      let id = register(step.id ?? "X")
      let handle = Handle(type: .phoneNumber, value: step.handle ?? "+1555555018\(ids.count)", displayName: step.name ?? "LCK \(step.id ?? "X")")
      let caps = step.capabilities.map(capabilities) ?? capabilities(config.capabilities ?? ["pausing", "merging", "unmerging"])
      let update = Conversation.Update(members: [handle], capabilities: caps)
      let entered = Date()
      log("reportStart", ["conv": step.id ?? "X", "uuid": id.uuidString, "handle": handle.value])
      do {
        try await manager.reportNewIncomingConversation(uuid: id, update: update)
        log("reported", ["conv": step.id ?? "X", "result": "ok", "afterMs": Int(Date().timeIntervalSince(entered) * 1000)])
      } catch {
        let ns = error as NSError
        log("reported", ["conv": step.id ?? "X", "result": "error", "domain": ns.domain, "code": ns.code,
                         "description": "\(error)", "afterMs": Int(Date().timeIntervalSince(entered) * 1000),
                         "appState": UIApplication.shared.applicationState.rawValue])
      }
    case "outgoing":
      let id = register(step.id ?? "X")
      let handle = Handle(type: .phoneNumber, value: step.handle ?? "+15555550170", displayName: step.name ?? "LCK \(step.id ?? "X")")
      await request("Start", StartConversationAction(conversationUUID: id, handles: [handle], isVideo: step.video ?? false))
    case "pause":
      guard let id = uuid(step.id) else { return missing(step) }
      await request("Pause", PauseConversationAction(conversationUUID: id, isPaused: step.paused ?? true))
    case "merge":
      guard let id = uuid(step.id), let other = uuid(step.other) else { return missing(step) }
      await request("Merge", MergeConversationAction(conversationUUID: id, conversationUUIDToMergeWith: other))
    case "unmerge":
      guard let id = uuid(step.id) else { return missing(step) }
      await request("Unmerge", UnmergeConversationAction(conversationUUID: id))
    case "end":
      guard let id = uuid(step.id) else { return missing(step) }
      await request("End", EndConversationAction(conversationUUID: id))
    case "remoteEnd":
      guard let c = conversation(step.id) else { return missing(step) }
      manager.reportConversationEvent(.conversationEnded(Date(), .remoteEnded), for: c)
    case "connect":
      guard let c = conversation(step.id) else { return missing(step) }
      manager.reportConversationEvent(.conversationConnected(Date()), for: c)
    case "caps":
      guard let c = conversation(step.id) else { return missing(step) }
      manager.reportConversationEvent(.conversationUpdated(Conversation.Update(capabilities: capabilities(step.capabilities))), for: c)
    case "waitState":
      let deadline = Date().addingTimeInterval(step.timeout ?? 45)
      let wanted = step.state ?? "joined"
      var seen = "missing"
      while Date() < deadline {
        seen = conversation(step.id).map { "\($0.state)" } ?? "missing"
        if seen == wanted || (wanted == "gone" && seen == "missing") { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      log("waitState", ["conv": step.id ?? "", "wanted": wanted, "seen": seen, "met": seen == wanted || (wanted == "gone" && seen == "missing")])
    case "waitAction":
      let deadline = Date().addingTimeInterval(step.timeout ?? 45)
      let kind = step.kind ?? "Join", count = step.count ?? 1
      var have = 0
      while Date() < deadline {
        have = { lock.lock(); defer { lock.unlock() }; return kindCounts[kind] ?? 0 }()
        if have >= count { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      log("waitAction", ["kind": kind, "count": count, "have": have, "met": have >= count])
    case "wait":
      try? await Task.sleep(for: .milliseconds(Int((step.s ?? 1) * 1000)))
    case "snapshot":
      snapshot(step.label ?? "step")
    case "status":
      setStatus(step.label ?? "mark")
    case "endAll":
      endAll()
    default:
      log("unknownOp", ["op": step.op])
    }
  }

  private func register(_ key: String) -> UUID {
    let id = UUID()
    lock.lock(); ids[key] = id; names[id] = key; lock.unlock()
    return id
  }

  private func missing(_ step: MultiStep) { log("missingConversation", ["op": step.op, "id": step.id ?? "", "other": step.other ?? ""]) }

  @MainActor private func request(_ kind: String, _ action: ConversationAction) async {
    let entered = Date()
    log("request", describe(action))
    do {
      try await manager.perform([action])
      log("requestResult", ["kind": kind, "action": action.uuid.uuidString, "conv": name(action.conversationUUID), "result": "ok",
                            "afterMs": Int(Date().timeIntervalSince(entered) * 1000)])
    } catch {
      let ns = error as NSError
      log("requestResult", ["kind": kind, "action": action.uuid.uuidString, "conv": name(action.conversationUUID), "result": "error",
                            "domain": ns.domain, "code": ns.code, "description": "\(error)",
                            "afterMs": Int(Date().timeIntervalSince(entered) * 1000)])
    }
    snapshot("after\(kind)Request")
  }

  // Leaves the phone clean: every remaining conversation ends as remote-ended.
  func endAll() {
    for c in manager.conversations where "\(c.state)" != "left" {
      manager.reportConversationEvent(.conversationEnded(Date(), .remoteEnded), for: c)
      log("endedByProbe", ["conv": name(c.uuid), "uuid": c.uuid.uuidString])
    }
  }

  // MARK: Fulfillment policy

  private func rule(_ kind: String, _ n: Int) -> FulfillRule {
    for key in [kind, "default"] {
      if let r = config.fulfill?[key], r.nth == nil || r.nth == n { return r }
    }
    return FulfillRule(mode: "immediate")
  }

  private func settle(_ action: ConversationAction, fail: Bool, how: String) {
    let kind = Self.kind(action)
    let at: Date? = { lock.lock(); defer { lock.unlock() }; return delivered[action.uuid] }()
    if fail {
      action.fail()
    } else {
      switch action {
      case let a as JoinConversationAction: a.fulfill(dateConnected: Date())
      case let a as StartConversationAction: a.fulfill(dateStarted: Date())
      case let a as EndConversationAction: a.fulfill(dateEnded: Date())
      default: action.fulfill()
      }
    }
    log("settled", ["kind": kind, "action": action.uuid.uuidString, "conv": name(action.conversationUUID), "failed": fail,
                    "how": how, "afterMs": at.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1,
                    "actionState": "\(action.state)"])
    if !fail, action is StartConversationAction,
       let c = manager.conversations.first(where: { $0.uuid == action.conversationUUID }) {
      manager.reportConversationEvent(.conversationStartedConnecting(Date()), for: c)
      DispatchQueue.main.asyncAfter(deadline: .now() + Double(config.connectAfterMs ?? 300) / 1000) {
        self.manager.reportConversationEvent(.conversationConnected(Date()), for: c)
        self.log("outgoingConnected", ["conv": self.name(c.uuid)])
      }
    }
  }

  private func flushReverse() {
    let batch: [ConversationAction] = { lock.lock(); defer { lock.unlock() }; let b = reverseBuffer; reverseBuffer = []; return b }()
    log("reverseFlush", ["order": batch.reversed().map { "\(Self.kind($0)):\(name($0.conversationUUID))" }])
    for action in batch.reversed() { settle(action, fail: false, how: "reverse") }
  }

  // MARK: ConversationManagerDelegate (callbacks have arrived on main on the device)

  func conversationManager(_ manager: ConversationManager, perform action: ConversationAction) {
    let kind = Self.kind(action)
    let n: Int = { lock.lock(); defer { lock.unlock() }; delivered[action.uuid] = Date(); kindCounts[kind, default: 0] += 1; return kindCounts[kind]! }()
    var f = describe(action)
    f["n"] = n; f["appState"] = UIApplication.shared.applicationState.rawValue
    log("perform", f)
    if action is JoinConversationAction || action is StartConversationAction {
      try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [])
    }
    let r = rule(kind, n)
    switch r.mode {
    case "delay":
      DispatchQueue.main.asyncAfter(deadline: .now() + Double(r.ms ?? 1000) / 1000) { self.settle(action, fail: false, how: "delay") }
    case "fail":
      settle(action, fail: true, how: "fail")
    case "pending":
      log("leftPending", ["kind": kind, "action": action.uuid.uuidString])
    case "reverse":
      let first: Bool = { lock.lock(); defer { lock.unlock() }; reverseBuffer.append(action); return reverseBuffer.count == 1 }()
      if first {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(config.reverseWindowMs ?? 500) / 1000) { self.flushReverse() }
      }
    default:
      settle(action, fail: false, how: "immediate")
    }
    log("performExit", ["kind": kind, "action": action.uuid.uuidString, "rule": r.mode])
  }

  func conversationManager(_ manager: ConversationManager, timedOutPerforming action: ConversationAction) {
    var f = describe(action)
    f["phase"] = "entry"
    log("timedOut", f)
    snapshot("afterTimeout")
  }

  func conversationManager(_ manager: ConversationManager, conversationChanged conversation: Conversation) {
    log("changed", ["conv": name(conversation.uuid), "uuid": conversation.uuid.uuidString, "state": "\(conversation.state)",
                    "debug": String(conversation.debugDescription.prefix(600))])
  }
  func conversationManagerDidBegin(_ manager: ConversationManager) { log("didBegin") }
  func conversationManagerDidReset(_ manager: ConversationManager) { log("didReset") }
  func conversationManager(_ manager: ConversationManager, didActivate audioSession: AVAudioSession) {
    log("didActivate", ["audio": audioState()])
  }
  func conversationManager(_ manager: ConversationManager, didDeactivate audioSession: AVAudioSession) {
    log("didDeactivate", ["audio": audioState()])
  }
}
