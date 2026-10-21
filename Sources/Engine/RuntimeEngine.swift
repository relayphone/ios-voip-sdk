import Foundation
@preconcurrency import CallKit
@preconcurrency import AVFoundation

#if !targetEnvironment(simulator)
#error("CallKit Simulator is a simulator-only runtime")
#endif

private struct BehaviorProfile: Decodable {
  let id: String
  let schemaVersion: Int
  let answerExpirySeconds: Double
  let ringTimeoutSeconds: Double
  let unknownProviderSeconds: Double
  let actionTimeoutSeconds: Double
  let startDeadlineSeconds: Double
  let answerDeadlineSeconds: Double
  let ordinaryDeadlineSeconds: Double
  let reportLatencySeconds: Double
  let muteEchoSeconds: Double
  let postEndUnmuteSeconds: Double
}

private final class ProviderRegistration: @unchecked Sendable {
  let provider: CXProvider
  weak var delegate: (any CXProviderDelegate)?
  var queue: DispatchQueue?
  var valid = true
  let reportQueue = DispatchQueue(label: "dev.callkitsim.report-completion")
  init(_ provider: CXProvider) { self.provider = provider }
}

private final class CallState: @unchecked Sendable {
  let id: UUID
  let reporter: ProviderRegistration
  var update: CXCallUpdate?
  var outgoing = false
  var connected = false
  var held = false
  var ended = false
  var muted = false
  var group: UUID
  var ringing = true
  var pushID = ""
  init(_ id: UUID, _ reporter: ProviderRegistration) {
    self.id = id; self.reporter = reporter; self.group = id
  }
  func snapshot() -> CXCall {
    CKSimMakeCall(id, outgoing, connected, held, ended)
  }
}

private enum ActionOrigin: String { case application, system, muteEcho, postEndUnmute }
private final class PendingAction: @unchecked Sendable {
  let action: CXAction
  let provider: ProviderRegistration
  let transaction: CXTransaction
  let origin: ActionOrigin
  var expired = false
  var settled = false
  init(_ action: CXAction, _ provider: ProviderRegistration, _ transaction: CXTransaction, _ origin: ActionOrigin) {
    self.action = action; self.provider = provider; self.transaction = transaction; self.origin = origin
  }
}

private final class ObserverRegistration: @unchecked Sendable {
  weak var observer: CXCallObserver?
  weak var delegate: (any CXCallObserverDelegate)?
  let queue: DispatchQueue
  init(_ observer: CXCallObserver, _ delegate: (any CXCallObserverDelegate)?, _ queue: DispatchQueue?) {
    self.observer = observer; self.delegate = delegate; self.queue = queue ?? .main
  }
}

private struct Faults: Codable {
  var staleAudio = false
  var reportCallbackDelayMS = 0
}
// Objective-C clients supply blocks without Swift Sendable annotations. The
// immutable block is transferred once and invoked only on its designated queue.
private final class Completion: @unchecked Sendable {
  let invoke: (Error?) -> Void
  init(_ invoke: @escaping (Error?) -> Void) { self.invoke = invoke }
}
private struct Command: Decodable {
  let id: UUID
  let runID: String
  let pid: Int
  let bundleID: String
  let operation: String
  var callUUID: UUID?
  var activeCallUUID: UUID?
  var held: Bool?
  var mustReport: Bool?
  var faults: Faults?
}

/// One private serial queue owns all state. App code always executes elsewhere.
@objc(CKSimulatorEngine)
final class RuntimeEngine: NSObject, CKRuntimeEngineProtocol, @unchecked Sendable {
  static let shared = RuntimeEngine()
  private let state = DispatchQueue(label: "dev.callkitsim.engine", qos: .userInitiated)
  private let stateKey = DispatchSpecificKey<Bool>()
  private let profile: BehaviorProfile
  private var providers: [ObjectIdentifier: ProviderRegistration] = [:]
  private var selected: ProviderRegistration?
  private let controllerQueues = NSMapTable<CXCallController, DispatchQueue>.weakToStrongObjects()
  private var calls: [UUID: CallState] = [:]
  private var pendingActions: [UUID: PendingAction] = [:]
  private let deadlines = NSMapTable<CXAction, NSDate>.weakToStrongObjects()
  private var observers: [ObjectIdentifier: ObserverRegistration] = [:]
  private var audioActive = false
  private var audioRevision: UInt64 = 0
  private var handoffPending = false
  private var faults = Faults()
  private let runID: String
  private let bundleID: String
  private let controlRoot: URL
  private var journal: FileHandle?
  private var sequence: UInt64 = 0
  private let epoch = DispatchTime.now().uptimeNanoseconds
  private var notificationToken: Int32 = 0
  private var commandResults: [UUID: [String: Any]] = [:]
  private var timers: [UUID: any DispatchSourceTimer] = [:]

  private override init() {
    let env = ProcessInfo.processInfo.environment
    let profileID = env["CKSIM_PROFILE"] ?? "ios-27.0"
    precondition(profileID == "ios-27.0", "Unsupported CallKit Simulator profile")
    let url = URL(fileURLWithPath: CKSimResourceDirectory()).appendingPathComponent("profiles/\(profileID).json")
    do { profile = try JSONDecoder().decode(BehaviorProfile.self, from: Data(contentsOf: url)) }
    catch { preconditionFailure("Missing or invalid CallKit Simulator profile") }
    precondition(profile.schemaVersion == 1 && profile.id == profileID)
    let requestedRun = env["CKSIM_RUN_ID"] ?? UUID().uuidString
    precondition(requestedRun.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil)
    runID = requestedRun
    bundleID = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    controlRoot = documents.appendingPathComponent(".callkit-simulator").appendingPathComponent(runID)
    super.init()
    state.setSpecific(key: stateKey, value: true)
    withState {
      do {
        for folder in [controlRoot, controlRoot.appendingPathComponent("requests"), controlRoot.appendingPathComponent("responses")] {
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let path = controlRoot.appendingPathComponent("events.jsonl")
        FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600])
        journal = try FileHandle(forWritingTo: path)
        let session: [String: Any] = ["schemaVersion": 1, "runID": runID, "pid": Int(getpid()),
          "bundleID": bundleID, "profile": profile.id, "notification": "dev.callkitsim.control.\(getpid())"]
        let data = try JSONSerialization.data(withJSONObject: session, options: [.sortedKeys])
        try data.write(to: documents.appendingPathComponent(".callkit-simulator/session.json"), options: .atomic)
      } catch { preconditionFailure("Cannot create CallKit Simulator control mailbox") }
    }
    let status = notify_register_dispatch("dev.callkitsim.control.\(getpid())", &notificationToken, state) { [weak self] _ in
      self?.processCommands()
    }
    precondition(status == NOTIFY_STATUS_OK, "Cannot register CallKit Simulator control mailbox")
    state.async { self.processCommands() }
  }

  private func withState<T>(_ body: () -> T) -> T {
    if DispatchQueue.getSpecific(key: stateKey) == true { return body() }
    return state.sync(execute: body)
  }
  private func after(_ seconds: Double, _ body: @escaping @Sendable () -> Void) {
    let id = UUID()
    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: state)
    timers[id] = timer
    timer.schedule(deadline: .now() + seconds, leeway: .milliseconds(1))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      let fired = self.timers.removeValue(forKey: id)
      fired?.setEventHandler(handler: nil)
      fired?.cancel()
      body()
    }
    timer.resume()
  }
  func record(event: String, fields: [String: Any]) {
    withState {
      sequence += 1
      var row = fields
      row.merge(["event": event, "sequence": sequence, "runID": runID, "pid": Int(getpid()),
                 "bundleID": bundleID, "profile": profile.id,
                 "t_ms": (DispatchTime.now().uptimeNanoseconds - epoch) / 1_000_000]) { _, new in new }
      if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
        journal?.write(data + Data([10]))
      }
    }
  }
  private func registration(_ provider: CXProvider) -> ProviderRegistration {
    let key = ObjectIdentifier(provider)
    if let value = providers[key] { return value }
    let value = ProviderRegistration(provider); providers[key] = value; return value
  }
  func register(provider: CXProvider) {
    withState {
      if selected != nil { record(event: "diagnostic.multipleProviders", fields: ["severity": "warning"]) }
      let entry = registration(provider)
      selected = entry
      after(0.05) { if entry.valid { self.callback(entry) { $0.providerDidBegin?(provider) } } }
      record(event: "provider.created", fields: ["provider": providerID(provider)])
    }
  }
  private func providerID(_ provider: CXProvider) -> String { String(describing: ObjectIdentifier(provider)) }
  private func callback(_ provider: ProviderRegistration, _ block: @escaping @Sendable (any CXProviderDelegate) -> Void) {
    guard let delegate = provider.delegate else { return }
    (provider.queue ?? .main).async { block(delegate) }
  }
  func set(provider: CXProvider, delegate: (any CXProviderDelegate)?, queue: DispatchQueue?) {
    withState {
      let value = registration(provider)
      value.delegate = delegate; value.queue = queue
    }
  }
  func register(controller: CXCallController, queue: DispatchQueue?) {
    withState { controllerQueues.setObject(queue ?? DispatchQueue(label: "dev.callkitsim.controller"), forKey: controller) }
  }
  func set(observer: CXCallObserver, delegate: (any CXCallObserverDelegate)?, queue: DispatchQueue?) {
    withState { observers[ObjectIdentifier(observer)] = ObserverRegistration(observer, delegate, queue) }
  }
  func liveCalls() -> [CXCall] { withState { calls.values.sorted { $0.id.uuidString < $1.id.uuidString }.map { $0.snapshot() } } }
  private func changed(_ call: CallState) {
    let snapshot = call.snapshot()
    record(event: "call.changed", fields: callJSON(call))
    observers = observers.filter { $0.value.observer != nil }
    for entry in observers.values {
      guard let observer = entry.observer, let delegate = entry.delegate else { continue }
      entry.queue.async { delegate.callObserver(observer, callChanged: snapshot) }
    }
  }
  private func callJSON(_ call: CallState) -> [String: Any] {
    ["uuid": call.id.uuidString, "outgoing": call.outgoing, "connected": call.connected,
     "held": call.held, "ended": call.ended, "muted": call.muted, "group": call.group.uuidString]
  }
  private func requestError(_ code: Int) -> NSError {
    NSError(domain: "com.apple.CallKit.error.requesttransaction", code: code)
  }
  private func validate(_ actions: [CXAction], origin: ActionOrigin) -> NSError? {
    if actions.isEmpty { return requestError(1) }
    var starts = Set<UUID>()
    for action in actions {
      guard let action = action as? CXCallAction else { return requestError(6) }
      if action is CXStartCallAction {
        if calls[action.callUUID] != nil || !starts.insert(action.callUUID).inserted { return requestError(5) }
      } else {
        guard calls[action.callUUID] != nil else { return requestError(4) }
        if action is CXAnswerCallAction && origin == .application && calls.values.contains(where: { $0.id != action.callUUID && !$0.ended }) {
          return requestError(6)
        }
        if let group = action as? CXSetGroupCallAction, let other = group.callUUIDToGroupWith, calls[other] == nil {
          return requestError(4)
        }
      }
    }
    return nil
  }
  func request(transaction: CXTransaction, controller: CXCallController, completion: @escaping (Error?) -> Void) {
    let reply = Completion(completion)
    let actions = transaction.actions.map { $0.copy() as! CXAction }
    let requestID = transaction.uuid
    withState {
      let queue = controllerQueues.object(forKey: controller) ?? DispatchQueue.global(qos: .userInitiated)
      guard let provider = selected, provider.valid else {
        record(event: "request.accepted", fields: ["transactionID": requestID.uuidString,
          "actionIDs": actions.map { $0.uuid.uuidString }, "error": 2])
        after(profile.unknownProviderSeconds) { queue.async { reply.invoke(self.requestError(2)) } }
        return
      }
      let error = validate(actions, origin: .application)
      record(event: "request.accepted", fields: ["transactionID": requestID.uuidString,
        "actionIDs": actions.map { $0.uuid.uuidString }, "error": error?.code ?? 0])
      if error == nil { reserveStarts(actions, provider) }
      // The continuation is scheduled only AFTER the client's completion returns.
      // No wall-clock timer, no app callback while executing the state queue.
      queue.async {
        reply.invoke(error)
        guard error == nil else { return }
        self.state.async { self.deliver(actions, provider, origin: .application, requestID: requestID) }
      }
    }
  }
  private func reserveStarts(_ actions: [CXAction], _ provider: ProviderRegistration) {
    for case let start as CXStartCallAction in actions {
      let call = CallState(start.callUUID, provider)
      call.outgoing = true; call.ringing = false; calls[call.id] = call; changed(call)
    }
  }
  private func deliver(_ actions: [CXAction], _ provider: ProviderRegistration, origin: ActionOrigin, requestID: UUID? = nil) {
    guard provider.valid else { return }
    // Creation with the same concrete actions intentionally yields a fresh transaction UUID.
    let delivered = CXTransaction(actions: actions)
    record(event: "transaction.delivered", fields: ["transactionID": delivered.uuid.uuidString,
      "requestID": requestID?.uuidString ?? "system", "origin": origin.rawValue,
      "provider": providerID(provider.provider), "actionIDs": actions.map { $0.uuid.uuidString },
      "kinds": actions.map { NSStringFromClass(type(of: $0)) }])
    for action in actions {
      let deadline = action is CXAnswerCallAction ? profile.answerDeadlineSeconds :
        (action is CXStartCallAction ? profile.startDeadlineSeconds : profile.ordinaryDeadlineSeconds)
      deadlines.setObject(Date(timeIntervalSinceNow: deadline) as NSDate, forKey: action)
      if let answer = action as? CXAnswerCallAction { calls[answer.callUUID]?.ringing = false }
      let pending = PendingAction(action, provider, delivered, origin)
      pendingActions[action.uuid] = pending
      let seconds = action is CXAnswerCallAction ? profile.answerExpirySeconds :
        (action is CXStartCallAction ? profile.startDeadlineSeconds : profile.actionTimeoutSeconds)
      after(seconds) { [weak self, weak pending] in
        guard let self, let pending, self.pendingActions[action.uuid] === pending, !pending.expired else { return }
        self.expire(pending)
      }
    }
    callback(provider) { CKSimPerform($0, provider.provider, delivered) }
  }
  private func expire(_ item: PendingAction) {
    if let answer = item.action as? CXAnswerCallAction {
      item.expired = true
      if calls[answer.callUUID] != nil { deliver([CXEndCallAction(call: answer.callUUID)], item.provider, origin: .system) }
      return
    }
    pendingActions.removeValue(forKey: item.action.uuid)
    record(event: "action.timeout", fields: ["actionID": item.action.uuid.uuidString, "origin": item.origin.rawValue])
    callback(item.provider) { $0.provider?(item.provider.provider, timedOutPerforming: item.action) }
    if let end = item.action as? CXEndCallAction { endCall(end.callUUID, provider: item.provider) }
  }
  func complete(action: CXAction, fulfilled: Bool) -> Bool {
    withState {
      guard let item = pendingActions[action.uuid] else { return false }
      if item.settled { return true }
      item.settled = true
      record(event: "action.settled", fields: ["actionID": action.uuid.uuidString,
        "fulfilled": fulfilled, "origin": item.origin.rawValue])
      if item.origin == .postEndUnmute { return true } // Device fulfills, then still times out.
      if item.expired { pendingActions.removeValue(forKey: action.uuid); return true }
      guard let callAction = action as? CXCallAction, let call = calls[callAction.callUUID] else {
        // A system end can arrive after an answer failure already removed the
        // call. Fulfillment is ignored, and the action's own timer still fires.
        return true
      }
      pendingActions.removeValue(forKey: action.uuid)
      if !fulfilled {
        if action is CXAnswerCallAction {
          after(0.29) { self.endCall(call.id, provider: item.provider) }
          after(0.3) { self.deliver([CXEndCallAction(call: call.id)], item.provider, origin: .system) }
        } else if action is CXStartCallAction { endCall(call.id, provider: item.provider) }
        return true
      }
      switch action {
      case is CXAnswerCallAction:
        call.connected = true; call.ringing = false; changed(call); reconcileAudio(provider: item.provider, delay: 0.29)
      case is CXStartCallAction:
        reconcileAudio(provider: item.provider, delay: 0.23)
      case is CXEndCallAction:
        endCall(call.id, provider: item.provider)
      case let hold as CXSetHeldCallAction:
        call.held = hold.isOnHold; changed(call); reconcileAudio(provider: item.provider, delay: hold.isOnHold ? 0.09 : 0.18)
      case let mute as CXSetMutedCallAction:
        call.muted = mute.isMuted
        if item.origin == .application {
          after(profile.muteEchoSeconds) {
            guard self.calls[call.id] === call else { return }
            self.deliver([CXSetMutedCallAction(call: call.id, muted: mute.isMuted)], item.provider, origin: .muteEcho)
          }
        }
      case let group as CXSetGroupCallAction:
        if let other = group.callUUIDToGroupWith, let target = calls[other] { call.group = target.group }
        else { call.group = call.id }
        record(event: "call.grouped", fields: callJSON(call))
      default: break
      }
      return true
    }
  }
  private func endCall(_ uuid: UUID, provider: ProviderRegistration) {
    guard let call = calls.removeValue(forKey: uuid) else { return }
    call.ended = true; call.ringing = false; changed(call)
    reconcileAudio(provider: provider, delay: calls.isEmpty ? 0.1 : 1.15)
    if call.muted {
      after(profile.postEndUnmuteSeconds) { self.deliver([CXSetMutedCallAction(call: uuid, muted: false)], provider, origin: .postEndUnmute) }
    }
  }
  func incoming(provider: CXProvider, uuid: UUID, update: CXCallUpdate, completion: @escaping (Error?) -> Void) {
    let reply = Completion(completion)
    let pushID = CKSimCurrentPushID()
    withState {
      let owner = registration(provider)
      if !owner.valid { owner.valid = true; callback(owner) { $0.providerDidBegin?(provider) } }
      record(event: "report.incoming", fields: ["callUUID": uuid.uuidString, "pushID": pushID])
      let error: NSError? = calls[uuid] == nil ? nil : NSError(domain: "com.apple.CallKit.error.incomingcall", code: 2)
      if error == nil {
        let call = CallState(uuid, owner); call.update = update.copy() as? CXCallUpdate; call.pushID = pushID
        calls[uuid] = call; changed(call)
        after(profile.ringTimeoutSeconds) {
          guard self.calls[uuid] === call, call.ringing else { return }
          self.deliver([CXEndCallAction(call: uuid)], self.selected ?? owner, origin: .system)
        }
      }
      let delay = (ProcessInfo.processInfo.environment["CKSIM_LATENCY"] == "device" ? profile.reportLatencySeconds : 0.02)
        + Double(faults.reportCallbackDelayMS) / 1000
      after(delay) {
        (owner.queue ?? owner.reportQueue).async {
          self.record(event: "report.completed", fields: ["callUUID": uuid.uuidString, "pushID": pushID, "error": error?.code ?? 0])
          reply.invoke(error)
        }
      }
    }
  }
  func updated(provider: CXProvider, uuid: UUID, update: CXCallUpdate) {
    withState { calls[uuid]?.update = update.copy() as? CXCallUpdate }
  }
  func ended(provider: CXProvider, uuid: UUID, reason: Int) {
    withState {
      record(event: "report.ended", fields: ["callUUID": uuid.uuidString, "reason": reason, "pushID": calls[uuid]?.pushID ?? ""])
      endCall(uuid, provider: selected ?? registration(provider))
    }
  }
  func connected(provider: CXProvider, uuid: UUID) {
    withState {
      guard let call = calls[uuid] else { return }
      call.connected = true; changed(call)
    }
  }
  func pending(provider: CXProvider) -> [CXTransaction] {
    withState {
      var seen = Set<UUID>()
      return pendingActions.values.filter { !$0.settled && $0.provider.provider === provider && seen.insert($0.transaction.uuid).inserted }.map(\.transaction)
    }
  }
  func deadline(action: CXAction) -> Date? { withState { deadlines.object(forKey: action) as Date? } }
  func pendingActions(provider: CXProvider, actionClass: AnyClass, uuid: UUID) -> [CXCallAction] {
    withState {
      pendingActions.values.filter { !$0.settled && $0.provider.provider === provider }
        .compactMap { $0.action as? CXCallAction }.filter { $0.isKind(of: actionClass) && $0.callUUID == uuid }
    }
  }
  func invalidate(provider: CXProvider) {
    withState {
      let value = registration(provider); value.valid = false
      audioRevision += 1
      for call in Array(calls.values) where call.reporter === value { endCall(call.id, provider: value) }
      pendingActions = pendingActions.filter { $0.value.provider !== value }
      record(event: "provider.invalidated", fields: ["provider": providerID(provider)])
    }
  }
  private func wantsAudio() -> Bool { calls.values.contains { !$0.held && ($0.connected || $0.outgoing) } }
  private func reconcileAudio(provider: ProviderRegistration, delay: Double) {
    if handoffPending { return }
    audioRevision += 1
    let revision = audioRevision
    let desired = wantsAudio()
    after(delay) {
      guard self.audioRevision == revision else { return }
      self.changeAudio(desired, provider: provider, revision: revision)
    }
  }
  private func changeAudio(_ desired: Bool, provider: ProviderRegistration, revision: UInt64) {
    guard desired != audioActive else {
      if !desired && handoffPending {
        handoffPending = false
        reconcileAudio(provider: provider, delay: 0.15)
      }
      return
    }
    if desired && faults.staleAudio { record(event: "fault.audioSuppressed", fields: [:]); return }
    DispatchQueue.main.async {
      guard self.withState({ self.audioRevision == revision }) else { return }
      do {
        try AVAudioSession.sharedInstance().setActive(desired, options: desired ? [] : [.notifyOthersOnDeactivation])
      } catch {
        self.withState {
          self.record(event: "audio.failed", fields: ["activating": desired])
          self.handoffPending = false
        }
        return
      }
      self.withState {
        self.audioActive = desired
        guard self.audioRevision == revision else {
          self.reconcileAudio(provider: self.selected ?? provider, delay: 0)
          return
        }
        self.record(event: desired ? "audio.activated" : "audio.deactivated", fields: [:])
        self.callback(provider) {
          if desired { $0.provider?(provider.provider, didActivate: AVAudioSession.sharedInstance()) }
          else { $0.provider?(provider.provider, didDeactivate: AVAudioSession.sharedInstance()) }
        }
        if !desired && self.handoffPending {
          self.handoffPending = false
          self.reconcileAudio(provider: provider, delay: 0.15)
        }
      }
    }
  }
  private func processCommands() {
    let folder = controlRoot.appendingPathComponent("requests")
    guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
      var remove = true
      defer { if remove { try? FileManager.default.removeItem(at: file) } }
      guard let bytes = try? Data(contentsOf: file), bytes.count <= 65_536,
            let command = try? JSONDecoder().decode(Command.self, from: bytes),
            command.runID == runID, command.pid == Int(getpid()), command.bundleID == bundleID,
            UUID(uuidString: file.deletingPathExtension().lastPathComponent) == command.id else { continue }
      let responseURL = controlRoot.appendingPathComponent("responses/\(command.id.uuidString).json")
      if FileManager.default.fileExists(atPath: responseURL.path) { continue }
      var response: [String: Any] = ["id": command.id.uuidString, "runID": runID, "pid": Int(getpid()), "bundleID": bundleID]
      if let cached = commandResults[command.id] { response = cached }
      else { do {
        let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] ?? [:]
        response["result"] = try execute(command, object)
        response["success"] = true
      } catch { response["success"] = false; response["error"] = String(describing: error) }
      commandResults[command.id] = response
      }
      do {
        let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        try data.write(to: responseURL, options: .atomic)
      } catch {
        remove = false
        record(event: "control.responseWriteFailed", fields: ["commandID": command.id.uuidString])
      }
    }
  }
  private func execute(_ command: Command, _ object: [String: Any]) throws -> [String: Any] {
    switch command.operation {
    case "status": return ["calls": calls.values.map(callJSON), "pending": pendingActions.values.filter { !$0.settled }.count, "audioActive": audioActive, "sequence": sequence]
    case "events": return ["events": (try? String(contentsOf: controlRoot.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? ""]
    case "inspect-adapter":
      let name = "CallKitVoIPPushDelegate"
      let selector = NSSelectorFromString("pushRegistry:didReceiveIncomingVoIPPushWithPayload:metadata:withCompletionHandler:")
      guard let cls = NSClassFromString(name) else { throw ControlError.invalid("adapter class missing") }
      return ["metadataSelector": class_getInstanceMethod(cls, selector) != nil]
    case "faults":
      guard let value = command.faults, (0...120_000).contains(value.reportCallbackDelayMS) else { throw ControlError.invalid("invalid faults") }
      faults = value; return ["configured": true]
    case "push":
      guard let payload = object["payload"] as? [String: Any], let mustReport = command.mustReport else { throw ControlError.invalid("payload and explicit mustReport required") }
      let bytes = try JSONSerialization.data(withJSONObject: payload)
      guard bytes.count <= 5120 else { throw ControlError.invalid("payload too large") }
      CKSimInjectPush(payload, mustReport, command.id.uuidString)
      return ["scheduled": true, "pushID": command.id.uuidString]
    default:
      guard let provider = selected, provider.valid, let uuid = command.callUUID, calls[uuid] != nil else { throw ControlError.invalid("unknown call or provider") }
      let actions: [CXAction]
      switch command.operation {
      case "answer": actions = [CXAnswerCallAction(call: uuid)]
      case "decline", "end": actions = [CXEndCallAction(call: uuid)]
      case "hold":
        guard let held = command.held else { throw ControlError.invalid("held required") }
        actions = [CXSetHeldCallAction(call: uuid, onHold: held)]
      case "hold-and-accept", "end-and-accept":
        guard let active = command.activeCallUUID, active != uuid, calls[active]?.connected == true else { throw ControlError.invalid("activeCallUUID required") }
        actions = [command.operation == "hold-and-accept" ? CXSetHeldCallAction(call: active, onHold: true) : CXEndCallAction(call: active), CXAnswerCallAction(call: uuid)]
      default: throw ControlError.invalid("unsupported operation")
      }
      if let error = validate(actions, origin: .system) { throw error }
      if command.operation == "hold-and-accept" || command.operation == "end-and-accept" {
        // The old call relinquishes audio before the new call acquires it.
        handoffPending = true
        audioRevision += 1
        let revision = audioRevision
        after(0.12) { self.changeAudio(false, provider: provider, revision: revision) }
      }
      deliver(actions, provider, origin: .system)
      return ["actionIDs": actions.map { $0.uuid.uuidString }]
    }
  }
}
private enum ControlError: Error { case invalid(String) }

@_cdecl("CKSimGetEngine")
func getRuntimeEngine() -> UnsafeMutableRawPointer {
  Unmanaged.passUnretained(RuntimeEngine.shared).toOpaque()
}
