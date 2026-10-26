import ActivityKit
import AVFoundation
import Intents
@preconcurrency import LiveCommunicationKit
import PushKit
import SwiftUI
import UserNotifications

struct ProbeConfig: Decodable {
  var rowID: String?
  var armed: Bool?
  var communicationNotification: Bool?
  var requestFocusAuthorization: Bool?
  var activityAction: String?
  var localUpdateInterval: Double?
  var localUpdateCount: Int?
  var ringTimeout: Double?
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
  let manager: ConversationManager
  let queue = DispatchQueue(label: "focus.pushkit")
  var registry: PKPushRegistry!
  override init() {
    manager = ConversationManager(configuration: .init(ringtoneName: nil, iconTemplateImageData: nil,
      maximumConversationGroups: 1, maximumConversationsPerConversationGroup: 1,
      includesConversationInRecents: false, supportsVideo: false, supportedHandleTypes: [.phoneNumber]))
    super.init()
    manager.delegate = self
    registry = PKPushRegistry(queue: queue); registry.delegate = self; registry.desiredPushTypes = [.voIP]
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
    Trace.shared.log("push.received", ["invitationID": id.uuidString, "mustReport": mustReport,
      "aiPolicy": UserDefaults(suiteName: ProbeFiles.group)?.string(forKey: "focus.aiPolicy") ?? "unset"])
    // Real incoming pushes are always reported, even if unarmed. Arming controls only auxiliary work.
    let update = Conversation.Update(members: [Handle(type: .phoneNumber, value: caller, displayName: "Focus Test Caller")], capabilities: [])
    let entered = DispatchSemaphore(value: 0)
    Task.detached(priority: .userInitiated) {
      Trace.shared.log("report.enter", ["invitationID": id.uuidString, "elapsedMs": Int((ProcessInfo.processInfo.systemUptime - start) * 1000)])
      entered.signal()
      do {
        try await self.manager.reportNewIncomingConversation(uuid: id, update: update)
        Trace.shared.log("report.result", ["invitationID": id.uuidString, "outcome": "reported", "elapsedMs": Int((ProcessInfo.processInfo.systemUptime - start) * 1000)])
        DispatchQueue.main.asyncAfter(deadline: .now() + min(max(config.ringTimeout ?? 25, 3), 60)) {
          if let call = self.manager.conversations.first(where: { $0.uuid == id }) {
            let answered = call.state == .joined
            self.manager.reportConversationEvent(.conversationEnded(Date(), answered ? .remoteEnded : .unanswered), for: call)
            Trace.shared.log("call.autoEnd", ["invitationID": id.uuidString, "answered": answered])
          }
        }
      } catch {
        var chain: [[String: Any]] = []; var e: NSError? = error as NSError
        for _ in 0..<4 {
          guard let current = e else { break }
          chain.append(["domain": current.domain, "code": current.code])
          e = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let reasons = [3: "focus", 4: "blockList", 5: "restrictedSharing", 6: "protectedCall", 7: "sensitiveParticipants"]
        let filtered = chain.first { ($0["domain"] as? String) == "com.apple.CallKit.error.incomingcall" && reasons[$0["code"] as? Int ?? -1] != nil }
        Trace.shared.log("report.result", ["invitationID": id.uuidString, "outcome": filtered == nil ? "failed" : "filtered",
          "reason": reasons[filtered?["code"] as? Int ?? -1] ?? "unknown", "errors": chain,
          "elapsedMs": Int((ProcessInfo.processInfo.systemUptime - start) * 1000)])
      }
      completion()
      Trace.shared.log("push.completion", ["invitationID": id.uuidString])
    }
    let signalled = entered.wait(timeout: .now() + 1) == .success
    Trace.shared.log("push.delegateReturn", ["reportTaskEntered": signalled])
    if config.armed == true, config.communicationNotification == true {
      Task { await CommunicationNotification.send(caller: caller, id: id) }
    }
    for delay in [1.0, 3, 10, 30] {
      queue.asyncAfter(deadline: .now() + delay) {
        Trace.shared.log("push.survival", ["invitationID": id.uuidString, "elapsedMs": Int((ProcessInfo.processInfo.systemUptime - start) * 1000)])
      }
    }
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
  static func send(caller: String, id: UUID) async {
    let person = INPerson(personHandle: INPersonHandle(value: caller, type: .phoneNumber), nameComponents: nil,
      displayName: "Focus Test Caller", image: nil, contactIdentifier: nil, customIdentifier: caller)
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
      Trace.shared.log("cn.scheduled", ["invitationID": id.uuidString])
    } catch { Trace.shared.log("cn.failed", ["domain": (error as NSError).domain, "code": (error as NSError).code]) }
  }
}

final class AppDelegate: NSObject, ObservableObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  @Published var authorizationSnapshot = "{}"
  var calls: Calls!
  var timer: Timer?
  func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    Trace.shared.log("app.launch", ["pid": Int(getpid()), "os": UIDevice.current.systemVersion])
    calls = Calls() // register before any authorization UI or scene work
    UNUserNotificationCenter.current().delegate = self
    return true
  }
  func activate() {
    Task { @MainActor in
      let config = ProbeConfig.load()
      FocusActivities.record = { Trace.shared.log($0, $1) }
      FocusActivities.discover()
      sampleFocus()
      if config.requestFocusAuthorization == true {
        _ = await INFocusStatusCenter.default.requestAuthorization()
        sampleFocus()
      }
      if config.activityAction == "start" { do { try FocusActivities.start(); Trace.shared.log("activity.start") } catch { Trace.shared.log("activity.startFailed", ["code": (error as NSError).code]) } }
      if config.activityAction == "end" { await FocusActivities.end(); Trace.shared.log("activity.end") }
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
