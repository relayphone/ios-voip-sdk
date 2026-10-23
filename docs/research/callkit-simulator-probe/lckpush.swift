import AVFoundation
import LiveCommunicationKit
import PushKit
import UIKit

// LiveCommunicationKit-only PushKit probe. No CXProvider is ever created here (D13).
// Configured by Documents/lck-push.json so cold launches (no environment) see it:
//   {"strategy": "entered" | "deferred", "autoEndAfterJoin": 5, "ringTimeout": 25,
//    "startOutgoing": false, "skipOptional": true}

struct LCKPushConfig: Codable {
  var strategy = "entered"
  var autoEndAfterJoin = 5.0
  var ringTimeout = 25.0
  var startOutgoing = false
  var skipOptional = true
  var deferSeconds: Double? = nil
  static func load() -> LCKPushConfig? {
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("lck-push.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(LCKPushConfig.self, from: data)
  }
}

final class LCKPushProbe: NSObject, PKPushRegistryDelegate, ConversationManagerDelegate, @unchecked Sendable {
  static var shared: LCKPushProbe?
  let config: LCKPushConfig
  let manager: ConversationManager
  let pushQueue = DispatchQueue(label: "probe.lck.push")
  var registry: PKPushRegistry?
  private let lock = NSLock()
  private var joinedAt: [UUID: Date] = [:]
  private var reportedAt: [UUID: Date] = [:]

  static func startIfConfigured() {
    guard shared == nil, let config = LCKPushConfig.load() else { return }
    shared = LCKPushProbe(config: config)
  }

  init(config: LCKPushConfig) {
    self.config = config
    let c = ConversationManager.Configuration(
      ringtoneName: nil, iconTemplateImageData: nil, maximumConversationGroups: 2, maximumConversationsPerConversationGroup: 1,
      includesConversationInRecents: false, supportsVideo: false, supportedHandleTypes: [.phoneNumber, .generic])
    manager = ConversationManager(configuration: c)
    super.init()
    manager.delegate = self
    Trace.shared.log("lckpush.launch", ["pid": Int(getpid()), "appState": UIApplication.shared.applicationState.rawValue,
                                        "strategy": config.strategy, "os": UIDevice.current.systemVersion, "build": osBuild()])
    let r = PKPushRegistry(queue: pushQueue)
    r.delegate = self
    r.desiredPushTypes = [.voIP]
    registry = r
    Trace.shared.log("lckpush.registered")
    // Heartbeat: proves the process survived its push handling.
    for i in 1...15 {
      DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 2) {
        Trace.shared.log("lckpush.alive", ["n": i, "appState": UIApplication.shared.applicationState.rawValue])
      }
    }
    if config.startOutgoing {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Task { await self.startOutgoing() } }
    }
  }

  func startOutgoing() async {
    let id = UUID()
    do {
      try await manager.perform([StartConversationAction(conversationUUID: id, handles: [Handle(type: .phoneNumber, value: "+15555550180")], isVideo: false)])
      Trace.shared.log("lckpush.outgoingRequested", ["conversation": short(id), "result": "ok"])
    } catch { Trace.shared.log("lckpush.outgoingRequested", ["result": "\(error)", "nsError": describe(error)]) }
  }

  // MARK: PushKit
  func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
    let hex = credentials.token.map { String(format: "%02x", $0) }.joined()
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    try? hex.write(to: dir.appendingPathComponent("voip-token.txt"), atomically: true, encoding: .utf8)
    Trace.shared.log("lckpush.token", ["bytes": credentials.token.count])
  }
  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) { Trace.shared.log("lckpush.tokenInvalidated") }

  @available(iOS 26.4, *)
  func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingVoIPPushWith payload: PKPushPayload,
                    metadata: PKVoIPPushMetadata, withCompletionHandler completion: @escaping () -> Void) {
    handle(payload, api: "metadata", mustReport: metadata.mustReport, completion: completion)
  }
  func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType,
                    completion: @escaping () -> Void) {
    handle(payload, api: "legacy", mustReport: true, completion: completion)
  }

  private func handle(_ payload: PKPushPayload, api: String, mustReport: Bool, completion: @escaping () -> Void) {
    let received = Date()
    let from = (payload.dictionaryPayload["from"] as? String) ?? "+15555550181"
    Trace.shared.log("lckpush.received", ["api": api, "mustReport": mustReport,
                                          "main": Thread.isMainThread, "strategy": config.strategy])
    if !mustReport && config.skipOptional {
      Trace.shared.log("lckpush.skippedOptional"); completion(); return
    }
    let id = UUID()
    let update = Conversation.Update(members: [Handle(type: .phoneNumber, value: from, displayName: "LCK Push")], capabilities: [.pausing])
    switch config.strategy {
    case "deferred":
      // The SDK's original behavior: return immediately, report later on the main actor.
      DispatchQueue.main.asyncAfter(deadline: .now() + (config.deferSeconds ?? 0)) {
        Task { @MainActor in
          await self.report(id, update, received: received)
          completion()
          Trace.shared.log("lckpush.completionCalled", ["afterMs": Int(Date().timeIntervalSince(received) * 1000)])
        }
      }
      Trace.shared.log("lckpush.delegateReturn", ["afterMs": Int(Date().timeIntervalSince(received) * 1000), "reportEntered": false])
    default:
      // Enter the report before returning; wait only on this private queue.
      let entered = DispatchSemaphore(value: 0)
      Task.detached(priority: .userInitiated) {
        entered.signal()
        await self.report(id, update, received: received)
        completion()
        Trace.shared.log("lckpush.completionCalled", ["afterMs": Int(Date().timeIntervalSince(received) * 1000)])
      }
      let waited = entered.wait(timeout: .now() + 2) == .success
      Thread.sleep(forTimeInterval: 0.05)
      Trace.shared.log("lckpush.delegateReturn", ["afterMs": Int(Date().timeIntervalSince(received) * 1000), "reportEntered": waited])
    }
  }

  private func report(_ id: UUID, _ update: Conversation.Update, received: Date) async {
    Trace.shared.log("lckpush.reportStart", ["conversation": short(id), "afterMs": Int(Date().timeIntervalSince(received) * 1000)])
    do {
      try await manager.reportNewIncomingConversation(uuid: id, update: update)
      lock.lock(); reportedAt[id] = Date(); lock.unlock()
      Trace.shared.log("lckpush.reported", ["conversation": short(id), "result": "ok", "afterMs": Int(Date().timeIntervalSince(received) * 1000)])
      DispatchQueue.main.asyncAfter(deadline: .now() + config.ringTimeout) { self.endIfStillRinging(id) }
    } catch {
      let ns = error as NSError
      Trace.shared.log("lckpush.reported", ["conversation": short(id), "result": "error", "domain": ns.domain, "code": ns.code,
                                            "description": "\(error)", "afterMs": Int(Date().timeIntervalSince(received) * 1000)])
    }
  }

  private func endIfStillRinging(_ id: UUID) {
    lock.lock(); let joined = joinedAt[id] != nil; lock.unlock()
    guard !joined, let c = manager.conversations.first(where: { $0.uuid == id }) else { return }
    manager.reportConversationEvent(.conversationEnded(Date(), .unanswered), for: c)
    Trace.shared.log("lckpush.endedUnanswered", ["conversation": short(id)])
  }

  // MARK: ConversationManagerDelegate (always observed on main so far)
  func conversationManager(_ manager: ConversationManager, conversationChanged conversation: Conversation) {
    Trace.shared.log("lckpush.changed", ["conversation": short(conversation.uuid), "state": "\(conversation.state)"])
  }
  func conversationManagerDidBegin(_ manager: ConversationManager) { Trace.shared.log("lckpush.didBegin") }
  func conversationManagerDidReset(_ manager: ConversationManager) { Trace.shared.log("lckpush.didReset") }
  func conversationManager(_ manager: ConversationManager, perform action: ConversationAction) {
    let kind = "\(type(of: action))"
    var f: [String: Any] = ["kind": kind, "conversation": short(action.conversationUUID),
                            "timeoutIn": (action.timeoutDate.timeIntervalSinceNow * 10).rounded() / 10]
    if let m = action as? MuteConversationAction { f["muted"] = m.isMuted }
    Trace.shared.log("lckpush.perform", f)
    if action is JoinConversationAction || action is StartConversationAction {
      try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [])
    }
    action.fulfill()
    if action is JoinConversationAction {
      let id = action.conversationUUID
      lock.lock(); joinedAt[id] = Date(); lock.unlock()
      DispatchQueue.main.asyncAfter(deadline: .now() + config.autoEndAfterJoin) {
        if let c = manager.conversations.first(where: { $0.uuid == id }) {
          manager.reportConversationEvent(.conversationEnded(Date(), .remoteEnded), for: c)
          Trace.shared.log("lckpush.autoEnded", ["conversation": short(id)])
        }
      }
    }
    if action is StartConversationAction, let c = manager.conversations.first(where: { $0.uuid == action.conversationUUID }) {
      manager.reportConversationEvent(.conversationStartedConnecting(Date()), for: c)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        manager.reportConversationEvent(.conversationConnected(Date()), for: c)
        Trace.shared.log("lckpush.outgoingConnected", ["conversation": short(c.uuid)])
      }
      // End the outgoing conversation after 40 s so the phone is left clean.
      DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
        manager.reportConversationEvent(.conversationEnded(Date(), .remoteEnded), for: c)
        Trace.shared.log("lckpush.outgoingEnded", ["conversation": short(c.uuid)])
      }
    }
  }
  func conversationManager(_ manager: ConversationManager, timedOutPerforming action: ConversationAction) {
    Trace.shared.log("lckpush.timedOut", ["kind": "\(type(of: action))"])
  }
  func conversationManager(_ manager: ConversationManager, didActivate audioSession: AVAudioSession) {
    lock.lock(); let joined = joinedAt.values.max(); lock.unlock()
    Trace.shared.log("lckpush.didActivate", ["msSinceJoin": joined.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1])
  }
  func conversationManager(_ manager: ConversationManager, didDeactivate audioSession: AVAudioSession) {
    Trace.shared.log("lckpush.didDeactivate")
  }
}

