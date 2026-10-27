import ActivityKit
import AVFoundation
import CallKit
import Intents
@preconcurrency import LiveCommunicationKit
import Network
import PushKit
import SwiftUI
import UserNotifications

struct ProbeConfig: Decodable {
  var rowID: String?
  var runID: String?
  var armed: Bool?
  var communicationNotification: Bool?
  var requestFocusAuthorization: Bool?
  var activityAction: String?
  var exportPushToStart: Bool?
  var localUpdateInterval: Double?
  var localUpdateCount: Int?
  var ringTimeout: Double?
  var provider: String?
  var handleType: String?
  static func load() -> ProbeConfig {
    guard let data = try? Data(contentsOf: ProbeFiles.documents.appendingPathComponent("focus.json")),
      let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
    return value
  }
}

final class Trace: @unchecked Sendable {
  static let shared = Trace()
  private let lock = NSLock()
  func log(_ event: String, _ fields: [String: Any] = [:]) {
    lock.lock(); defer { lock.unlock() }
    var record = fields
    record["event"] = event
    record["rowID"] = ProbeConfig.load().rowID ?? "idle"
    record["runID"] = ProbeConfig.load().runID ?? "idle"
    record["monoMs"] = Int(ProcessInfo.processInfo.systemUptime * 1000)
    record["wallMs"] = Int(Date().timeIntervalSince1970 * 1000)
    record["main"] = Thread.isMainThread
    guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
    data.append(10)
    let url = ProbeFiles.documents.appendingPathComponent("focus.jsonl")
    if !FileManager.default.fileExists(atPath: url.path) { try? ProbeFiles.write("focus.jsonl", data: Data()) }
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data)
    }
  }
}

final class Calls: NSObject, PKPushRegistryDelegate, ConversationManagerDelegate, @unchecked Sendable {
  private struct AnswerSignal: Decodable {
    let runID: String
    let invitationID: UUID
    let signalID: UUID
  }
  private enum ReportPhase { case pending, active, ended }
  private struct TrackedReport {
    let runID: String
    var phase: ReportPhase
    var pendingSignal: AnswerSignal?
  }
  let manager: ConversationManager?
  let callKit: CallKitControl?
  let mode: String
  let queue = DispatchQueue(label: "focus.pushkit")
  var registry: PKPushRegistry!
  private var signalTimer: DispatchSourceTimer?
  // Accessed only on queue, including callbacks dispatched from other threads.
  private var reports: [UUID: TrackedReport] = [:]
  private var seenSignals: Set<UUID> = []
  override init() {
    mode = ProbeConfig.load().provider == "callkit" ? "callkit" : "lck"
    if mode == "callkit" {
      manager = nil
      callKit = CallKitControl()
    } else {
      callKit = nil
      manager = ConversationManager(configuration: .init(ringtoneName: nil, iconTemplateImageData: nil,
        maximumConversationGroups: 1, maximumConversationsPerConversationGroup: 1,
        includesConversationInRecents: false, supportsVideo: false, supportedHandleTypes: [.phoneNumber, .generic]))
    }
    super.init()
    manager?.delegate = self
    Trace.shared.log("provider.selected", ["provider": mode])
    registry = PKPushRegistry(queue: queue); registry.delegate = self; registry.desiredPushTypes = [.voIP]
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(200), leeway: .milliseconds(50))
    timer.setEventHandler { [weak self] in self?.pollAnswerSignal() }
    signalTimer = timer
    timer.resume()
  }
  func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
    try? ProbeFiles.write("voip-token.txt", data: Data(credentials.token.map { String(format: "%02x", $0) }.joined().utf8))
    Trace.shared.log("push.token", ["bytes": credentials.token.count])
  }
  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    try? FileManager.default.removeItem(at: ProbeFiles.documents.appendingPathComponent("voip-token.txt"))
    Trace.shared.log("push.tokenInvalidated")
  }
  @available(iOS 26.4, *)
  func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingVoIPPushWith payload: PKPushPayload,
    metadata: PKVoIPPushMetadata, withCompletionHandler completion: @escaping () -> Void) {
    receive(payload, mustReport: metadata.mustReport, completion: completion)
  }
  func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType, completion: @escaping () -> Void) {
    receive(payload, mustReport: true, completion: completion)
  }
  private func receive(_ payload: PKPushPayload, mustReport: Bool, completion: @escaping () -> Void) {
    let start = ProcessInfo.processInfo.systemUptime
    let config = ProbeConfig.load()
    let id = (payload.dictionaryPayload["invitationID"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
    let caller = payload.dictionaryPayload["from"] as? String ?? "+15555550199"
    let kind = config.handleType == "generic" ? "generic" : "phoneNumber"
    // Each genuine call is reported even if an unrelated mailbox signal exists.
    reports[id] = TrackedReport(runID: config.runID ?? "idle", phase: .pending)
    Trace.shared.log("push.received", ["invitationID": id.uuidString, "mustReport": mustReport, "provider": mode,
      "handleType": kind, "handleValue": caller,
      "aiPolicy": UserDefaults(suiteName: ProbeFiles.group)?.string(forKey: "focus.aiPolicy") ?? "unset"])
    // Real incoming pushes are always reported, even if unarmed. Arming controls only auxiliary work.
    let finished: (Error?) -> Void = { error in
      self.queue.async {
        self.reportFinished(id, start: start, error: error)
        if var report = self.reports[id], report.phase == .pending {
          let signal = report.pendingSignal
          report.phase = error == nil ? .active : .ended
          report.pendingSignal = nil
          self.reports[id] = report
          if let signal {
            if error == nil { self.applyAnswerSignal(signal) }
            else { self.logSignal("answer.ignored", signal, reason: "reportFailed") }
          }
        }
        completion(); Trace.shared.log("push.completion", ["invitationID": id.uuidString, "provider": self.mode])
      }
    }
    let ringTimeout = min(max(config.ringTimeout ?? 25, 3), 60)
    if let callKit {
      Trace.shared.log("report.enter", ["invitationID": id.uuidString, "provider": mode, "elapsedMs": Int((ProcessInfo.processInfo.systemUptime - start) * 1000)])
      callKit.report(id: id, caller: caller, kind: kind, ringTimeout: ringTimeout, completion: finished)
      Trace.shared.log("push.delegateReturn", ["reportTaskEntered": true, "provider": mode])
    } else if manager != nil {
      let update = Conversation.Update(members: [Handle(type: kind == "generic" ? .generic : .phoneNumber, value: caller, displayName: "Focus Test Caller")], capabilities: [])
      let entered = DispatchSemaphore(value: 0)
      Task.detached(priority: .userInitiated) {
        guard let manager = self.manager else { return }
        Trace.shared.log("report.enter", ["invitationID": id.uuidString, "provider": self.mode, "elapsedMs": Int((ProcessInfo.processInfo.systemUptime - start) * 1000)])
        entered.signal()
        do {
          try await manager.reportNewIncomingConversation(uuid: id, update: update)
          finished(nil)
          DispatchQueue.main.asyncAfter(deadline: .now() + ringTimeout) {
            self.queue.async {
              guard var report = self.reports[id], report.phase == .active else { return }
              report.phase = .ended
              self.reports[id] = report
              if let manager = self.manager, let call = manager.conversations.first(where: { $0.uuid == id }) {
                let answered = call.state == .joined
                manager.reportConversationEvent(.conversationEnded(Date(), answered ? .remoteEnded : .unanswered), for: call)
                Trace.shared.log("call.autoEnd", ["invitationID": id.uuidString, "answered": answered, "provider": self.mode])
              }
            }
          }
        } catch { finished(error) }
      }
      let signalled = entered.wait(timeout: .now() + 1) == .success
      Trace.shared.log("push.delegateReturn", ["reportTaskEntered": signalled, "provider": mode])
    }
    if config.armed == true, config.communicationNotification == true {
      Task { await CommunicationNotification.send(caller: caller, id: id, kind: kind) }
    }
    for delay in [1.0, 3, 10, 30] {
      queue.asyncAfter(deadline: .now() + delay) {
        Trace.shared.log("push.survival", ["invitationID": id.uuidString, "elapsedMs": Int((ProcessInfo.processInfo.systemUptime - start) * 1000)])
      }
    }
  }
  private func logSignal(_ event: String, _ signal: AnswerSignal, reason: String? = nil) {
    var fields: [String: Any] = ["invitationID": signal.invitationID.uuidString,
                                 "signalID": signal.signalID.uuidString, "provider": mode]
    if let reason { fields["reason"] = reason }
    Trace.shared.log(event, fields)
  }
  // A local mailbox lets the device operator simulate a server answer without a
  // cancellation-only VoIP push. Polling has no execution guarantee in suspension.
  private func pollAnswerSignal() {
    let url = ProbeFiles.documents.appendingPathComponent("answer-signal.json")
    guard let data = try? Data(contentsOf: url),
          let signal = try? JSONDecoder().decode(AnswerSignal.self, from: data),
          seenSignals.insert(signal.signalID).inserted else { return }
    logSignal("answer.signal", signal)
    let config = ProbeConfig.load()
    guard config.armed == true, config.runID == signal.runID else {
      logSignal("answer.ignored", signal, reason: "runMismatchOrDisarmed"); return
    }
    guard var report = reports[signal.invitationID], report.runID == signal.runID else {
      logSignal("answer.ignored", signal, reason: "unknownInvitation"); return
    }
    switch report.phase {
    case .pending:
      guard report.pendingSignal == nil else { logSignal("answer.ignored", signal, reason: "alreadyPending"); return }
      report.pendingSignal = signal
      reports[signal.invitationID] = report
      logSignal("answer.deferred", signal, reason: "incomingReportPending")
    case .active: applyAnswerSignal(signal)
    case .ended: logSignal("answer.ignored", signal, reason: "alreadyEnded")
    }
  }
  private func applyAnswerSignal(_ signal: AnswerSignal) {
    guard var report = reports[signal.invitationID], report.phase == .active else {
      logSignal("answer.ignored", signal, reason: "notActive"); return
    }
    // Mark terminal before reporting to prevent a duplicate or local timeout racing it.
    report.phase = .ended
    reports[signal.invitationID] = report
    if let callKit {
      guard callKit.answeredElsewhere(id: signal.invitationID) else {
        logSignal("answer.ignored", signal, reason: "notRinging"); return
      }
      logSignal("answer.report", signal, reason: "answeredElsewhere")
    } else if let manager, let conversation = manager.conversations.first(where: { $0.uuid == signal.invitationID }),
              conversation.state == .idle {
      manager.reportConversationEvent(.conversationEnded(Date(), .joinedElsewhere), for: conversation)
      logSignal("answer.report", signal, reason: "joinedElsewhere")
    } else {
      logSignal("answer.ignored", signal, reason: "notRinging")
    }
  }
  private func reportFinished(_ id: UUID, start: TimeInterval, error: Error?) {
    var fields: [String: Any] = ["invitationID": id.uuidString, "provider": mode,
      "elapsedMs": Int((ProcessInfo.processInfo.systemUptime - start) * 1000)]
    if let error {
      var chain: [[String: Any]] = []; var e: NSError? = error as NSError
      for _ in 0..<4 {
        guard let current = e else { break }
        chain.append(["domain": current.domain, "code": current.code])
        e = current.userInfo[NSUnderlyingErrorKey] as? NSError
      }
      let reasons = [3: "focus", 4: "blockList", 5: "restrictedSharing", 6: "protectedCall", 7: "sensitiveParticipants"]
      let filtered = chain.first { ($0["domain"] as? String) == "com.apple.CallKit.error.incomingcall" && reasons[$0["code"] as? Int ?? -1] != nil }
      fields["outcome"] = filtered == nil ? "failed" : "filtered"
      fields["reason"] = reasons[filtered?["code"] as? Int ?? -1] ?? "unknown"
      fields["errors"] = chain
    } else { fields["outcome"] = "reported" }
    Trace.shared.log("report.result", fields)
  }
  func conversationManagerDidBegin(_ manager: ConversationManager) { Trace.shared.log("call.begin") }
  func conversationManagerDidReset(_ manager: ConversationManager) { Trace.shared.log("call.reset") }
  func conversationManager(_ manager: ConversationManager, conversationChanged conversation: Conversation) {
    Trace.shared.log("call.changed", ["invitationID": conversation.uuid.uuidString, "state": "\(conversation.state)"])
  }
  func conversationManager(_ manager: ConversationManager, perform action: ConversationAction) {
    Trace.shared.log("call.action", ["kind": "\(type(of: action))", "invitationID": action.conversationUUID.uuidString])
    // UI/reporting probe only: no microphone, media engine or pretend AI connection.
    action.fulfill()
  }
  func conversationManager(_ manager: ConversationManager, timedOutPerforming action: ConversationAction) { Trace.shared.log("call.actionTimeout") }
  func conversationManager(_ manager: ConversationManager, didActivate audioSession: AVAudioSession) { Trace.shared.log("call.audioActivated") }
  func conversationManager(_ manager: ConversationManager, didDeactivate audioSession: AVAudioSession) { Trace.shared.log("call.audioDeactivated") }
}

enum CommunicationNotification {
  static func send(caller: String, id: UUID, kind: String) async {
    let intentKind = kind == "generic" ? "unknown" : "phoneNumber"
    Trace.shared.log("cn.intent", ["invitationID": id.uuidString, "callHandleType": kind,
      "intentHandleType": intentKind, "handleValue": caller])
    let person = INPerson(personHandle: INPersonHandle(value: caller, type: kind == "generic" ? .unknown : .phoneNumber), nameComponents: nil,
      displayName: "Focus Test Caller", image: nil, contactIdentifier: nil, customIdentifier: caller, aliases: nil, suggestionType: .none)
    let intent = INStartCallIntent(callRecordFilter: nil, callRecordToCallBack: nil, audioRoute: .unknown,
      destinationType: .normal, contacts: [person], callCapability: .audioCall)
    let interaction = INInteraction(intent: intent, response: nil); interaction.direction = .incoming
    do {
      try await interaction.donate()
      let content = UNMutableNotificationContent()
      content.title = "Focus Test Caller"; content.body = "Synthetic incoming call notification"
      content.interruptionLevel = .active; content.sound = .default
      let updated = try content.updating(from: intent)
      try await UNUserNotificationCenter.current().add(.init(identifier: "focus.cn.\(id)", content: updated, trigger: nil))
      Trace.shared.log("cn.scheduled", ["invitationID": id.uuidString, "callHandleType": kind,
        "intentHandleType": intentKind, "handleValue": caller])
    } catch { Trace.shared.log("cn.failed", ["domain": (error as NSError).domain, "code": (error as NSError).code]) }
  }
}

final class AppDelegate: NSObject, ObservableObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  @Published var authorizationSnapshot = "{}"
  var calls: Calls!
  var timer: Timer?
  private let networkQueue = DispatchQueue(label: "focus.activity-network")
  private var networkMonitor: NWPathMonitor?
  // Read and written only on networkQueue after the monitor has started.
  private var lastNetworkUpdateAtMs: Int?
  private var lastNetworkUpdateUptimeMs: Int?
  func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    Trace.shared.log("app.launch", ["pid": Int(getpid()), "os": UIDevice.current.systemVersion])
    calls = Calls() // register before any authorization UI or scene work
    UNUserNotificationCenter.current().delegate = self
    startNetworkObservation()
    // A remote start may launch the app in the background. Discover existing
    // activities and tokens without requesting a new activity in this path.
    Task { @MainActor in
      FocusActivities.record = { Trace.shared.log($0, $1) }
      FocusActivities.observeAuthorization()
      FocusActivities.observePushToStart(enabled: ProbeConfig.load().exportPushToStart == true)
      FocusActivities.discover()
    }
    return true
  }
  func activate() {
    sampleNetworkAtActivation()
    Task { @MainActor in
      let config = ProbeConfig.load()
      FocusActivities.record = { Trace.shared.log($0, $1) }
      FocusActivities.observeAuthorization()
      FocusActivities.observePushToStart(enabled: config.exportPushToStart == true)
      FocusActivities.discover()
      sampleFocus()
      if config.requestFocusAuthorization == true {
        _ = await INFocusStatusCenter.default.requestAuthorization()
        sampleFocus()
      }
      if config.activityAction == "start" { do { try FocusActivities.start(); Trace.shared.log("activity.start") } catch { Trace.shared.log("activity.startFailed", ["code": (error as NSError).code]) } }
      if config.activityAction == "end" { await FocusActivities.end(); Trace.shared.log("activity.end") }
      if config.activityAction == "reset" { await FocusActivities.reset() }
      if config.activityAction == "snapshot" { FocusActivities.snapshotCapabilities() }
      timer?.invalidate()
      var remaining = min(max(config.localUpdateCount ?? 12, 0), 120)
      if let interval = config.localUpdateInterval, interval >= 1, remaining > 0 {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
          guard remaining > 0 else { timer.invalidate(); return }
          remaining -= 1
          Task { @MainActor in await FocusActivities.update(); Trace.shared.log("activity.localUpdate") }
        }
      }
    }
  }
  private func startNetworkObservation() {
    let monitor = NWPathMonitor()
    networkMonitor = monitor
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      self.lastNetworkUpdateAtMs = Int(Date().timeIntervalSince1970 * 1000)
      self.lastNetworkUpdateUptimeMs = Int(ProcessInfo.processInfo.systemUptime * 1000)
      self.writeNetworkSnapshot(path, source: "pathUpdate")
    }
    monitor.start(queue: networkQueue)
  }
  private func sampleNetworkAtActivation() {
    networkQueue.async { [weak self] in
      guard let self else { return }
      // A cached activation sample is not proof of a newly delivered path
      // callback after Settings changed the connectivity switches.
      let current = self.lastNetworkUpdateAtMs == nil ? nil : self.networkMonitor?.currentPath
      self.writeNetworkSnapshot(current, source: "activation")
    }
  }
  private func writeNetworkSnapshot(_ path: NWPath?, source: String) {
    func interfaceName(_ type: NWInterface.InterfaceType) -> String {
      switch type {
      case .wifi: return "wifi"
      case .cellular: return "cellular"
      case .wiredEthernet: return "wiredEthernet"
      case .loopback: return "loopback"
      case .other: return "other"
      @unknown default: return "unknown"
      }
    }
    let status: String
    if let path {
      switch path.status {
      case .satisfied: status = "satisfied"
      case .unsatisfied: status = "unsatisfied"
      case .requiresConnection: status = "requiresConnection"
      @unknown default: status = "unknown"
      }
    } else { status = "unknown" }
    let interfaces = path.map { Array(Set($0.availableInterfaces.map { interfaceName($0.type) })).sorted() } ?? []
    let snapshot: [String: Any] = ["status": status, "availableInterfaces": interfaces,
      "usesWiFi": path.map { $0.usesInterfaceType(.wifi) as Any } ?? NSNull(),
      "usesCellular": path.map { $0.usesInterfaceType(.cellular) as Any } ?? NSNull(),
      "source": source, "pathReady": path != nil, "observedAtMs": Int(Date().timeIntervalSince1970 * 1000),
      "lastPathUpdateAtMs": lastNetworkUpdateAtMs.map { $0 as Any } ?? NSNull(),
      "lastPathUpdateUptimeMs": lastNetworkUpdateUptimeMs.map { $0 as Any } ?? NSNull(),
      "runID": ProbeConfig.load().runID ?? "idle"]
    do {
      let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
      // Preserve the last actual callback separately: an activation sample can
      // replace the general snapshot before the host has read the callback.
      if source == "pathUpdate" { try ProbeFiles.write("activity-network-update.json", data: data) }
      try ProbeFiles.write("activity-network.json", data: data)
      Trace.shared.log("activity.network", snapshot)
    } catch { Trace.shared.log("activity.networkExportFailed") }
  }
  func sampleFocus() {
    let center = INFocusStatusCenter.default
    Trace.shared.log("focus.sample", ["authorization": center.authorizationStatus.rawValue,
      "isFocused": center.focusStatus.isFocused.map { $0 as Any } ?? NSNull(),
      "aiPolicy": UserDefaults(suiteName: ProbeFiles.group)?.string(forKey: "focus.aiPolicy") ?? "unset",
      "frequentPushesEnabled": ActivityAuthorizationInfo().frequentPushesEnabled])
    let focus = center.authorizationStatus.rawValue
    UNUserNotificationCenter.current().getNotificationSettings { value in
      DispatchQueue.main.async {
        let snapshot = ["focus": focus, "notifications": value.authorizationStatus.rawValue]
        if let data = try? JSONSerialization.data(withJSONObject: snapshot), let text = String(data: data, encoding: .utf8) {
          self.authorizationSnapshot = text
          Trace.shared.log("authorization.sample", snapshot)
        }
      }
    }
  }
  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    Trace.shared.log("cn.foregroundDelivery"); completionHandler([.banner, .sound, .list])
  }
}

@main struct FocusProbeApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
  var body: some Scene {
    WindowGroup { ProbeView(delegate: delegate) }
  }
}

// An App body does not reliably re-render for its delegate's @Published changes; a View observes it.
struct ProbeView: View {
  @ObservedObject var delegate: AppDelegate
  @Environment(\.scenePhase) var phase
  var body: some View {
    VStack(spacing: 20) {
      Text("Focus Probe").font(.title)
      Text("Synthetic call and transcript measurements. No AI or media connection.")
      Text(delegate.authorizationSnapshot).accessibilityIdentifier("focus.authorization.snapshot").font(.caption)
      Button("Authorize notifications") {
        Task { let granted = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]); Trace.shared.log("cn.authorization", ["granted": granted ?? false]) }
      }.accessibilityIdentifier("focus.notifications")
      Button("Sample Focus") { delegate.sampleFocus() }.accessibilityIdentifier("focus.sample")
      Button("Authorize Focus status") {
        INFocusStatusCenter.default.requestAuthorization { _ in DispatchQueue.main.async { delegate.sampleFocus() } }
      }.accessibilityIdentifier("focus.authorize")
      Button("Start silent transcript") {
        do { try FocusActivities.start(); Trace.shared.log("activity.start") } catch { Trace.shared.log("activity.startFailed", ["code": (error as NSError).code]) }
      }.accessibilityIdentifier("focus.activity.start")
      Button("End transcript") { Task { await FocusActivities.end() } }.accessibilityIdentifier("focus.activity.end")
    }.padding().onChange(of: phase) { _, value in if value == .active { delegate.activate() } }
  }
}
