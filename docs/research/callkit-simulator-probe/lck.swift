// The macOS 27 SDK's Catalyst LiveCommunicationKit lacks the delegate's audio requirements, so conformance can't link there.
#if !targetEnvironment(macCatalyst)
import AVFoundation
import CallKit
import LiveCommunicationKit
import UIKit

// LiveCommunicationKit behavior and its coexistence with CXProvider.
// PROBE_MODE=lck PROBE_LCK=<scenario>; one scenario per launch, then the app exits.

final class LCKTap: NSObject, ConversationManagerDelegate, CXProviderDelegate, @unchecked Sendable {
  let label: String
  static var muteFulfillDelay: Double = 0
  init(_ label: String) { self.label = label }
  func log(_ event: String, _ fields: [String: Any] = [:]) {
    var f = fields
    f["p"] = label
    Trace.shared.log("lck." + event, f)
  }
  static func describe(_ c: Conversation) -> [String: Any] {
    ["uuid": String(c.uuid.uuidString.prefix(8)), "state": "\(c.state)"]
  }

  // ConversationManagerDelegate
  func conversationManager(_ manager: ConversationManager, conversationChanged conversation: Conversation) {
    log("conversationChanged", LCKTap.describe(conversation))
  }
  func conversationManagerDidBegin(_ manager: ConversationManager) { log("didBegin") }
  func conversationManagerDidReset(_ manager: ConversationManager) { log("didReset") }
  func conversationManager(_ manager: ConversationManager, perform action: ConversationAction) {
    let deadline = action.timeoutDate
    let sampled = Date()
    var f: [String: Any] = ["kind": "\(type(of: action))", "action": String(action.uuid.uuidString.prefix(8)),
                            "actionID": action.uuid.uuidString,
                            "deadlineMS": Int64(deadline.timeIntervalSince1970 * 1000),
                            "sampledAtMS": Int64(sampled.timeIntervalSince1970 * 1000),
                            "conversation": String(action.conversationUUID.uuidString.prefix(8)),
                            "timeoutIn": (deadline.timeIntervalSince(sampled) * 10).rounded() / 10, "state": "\(action.state)"]
    if let m = action as? MuteConversationAction { f["muted"] = m.isMuted }
    if let p = action as? PauseConversationAction { f["paused"] = p.isPaused }
    log("perform", f)
    if action is StartConversationAction || action is JoinConversationAction {
      try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [])
    }
    if action is MuteConversationAction, LCKTap.muteFulfillDelay > 0 {
      let delay = LCKTap.muteFulfillDelay
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        action.fulfill(); self.log("muteFulfilled", ["action": String(action.uuid.uuidString.prefix(8)), "delayMs": Int(delay * 1000)])
      }
      return
    }
    action.fulfill()
    if action is StartConversationAction, let c = manager.conversations.first(where: { $0.uuid == action.conversationUUID }) {
      manager.reportConversationEvent(.conversationStartedConnecting(Date()), for: c)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        manager.reportConversationEvent(.conversationConnected(Date()), for: c)
        self.log("reported.connected")
      }
    }
  }
  func conversationManager(_ manager: ConversationManager, timedOutPerforming action: ConversationAction) {
    log("timedOut", ["kind": "\(type(of: action))", "action": String(action.uuid.uuidString.prefix(8))])
  }
  func conversationManager(_ manager: ConversationManager, didActivate audioSession: AVAudioSession) { log("didActivate") }
  func conversationManager(_ manager: ConversationManager, didDeactivate audioSession: AVAudioSession) { log("didDeactivate") }

  // CXProviderDelegate, for coexistence scenarios
  func providerDidBegin(_ provider: CXProvider) { log("cx.didBegin") }
  func providerDidReset(_ provider: CXProvider) { log("cx.didReset") }
  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    log("cx.perform", ["kind": "CXStartCallAction"]); action.fulfill()
  }
  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) { log("cx.perform", ["kind": "CXAnswerCallAction"]); action.fulfill() }
  func provider(_ provider: CXProvider, perform action: CXEndCallAction) { log("cx.perform", ["kind": "CXEndCallAction"]); action.fulfill() }
  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) { log("cx.perform", ["kind": "CXSetMutedCallAction"]); action.fulfill() }
}

final class LCKProbe: NSObject, CXCallObserverDelegate, @unchecked Sendable {
  let observer = CXCallObserver()
  var managers: [ConversationManager] = []
  var cxProviders: [CXProvider] = []
  var taps: [LCKTap] = []
  let tapB = LCKTap("C")

  func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
  func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
    Trace.shared.log("observer.callChanged", describe(call))
  }
  func makeManager(_ label: String = "L") -> ConversationManager {
    let config = ConversationManager.Configuration(
      ringtoneName: nil, iconTemplateImageData: nil, maximumConversationGroups: 2, maximumConversationsPerConversationGroup: 1,
      includesConversationInRecents: false, supportsVideo: false, supportedHandleTypes: [.phoneNumber, .generic])
    let m = ConversationManager(configuration: config)
    let tap = LCKTap(label)
    taps.append(tap)
    m.delegate = tap
    managers.append(m)
    Trace.shared.log("lck.managerCreated", ["p": label])
    return m
  }
  func makeProvider() -> CXProvider {
    let c = CXProviderConfiguration()
    c.supportedHandleTypes = [.phoneNumber, .generic]
    c.includesCallsInRecents = false
    let p = CXProvider(configuration: c)
    p.setDelegate(tapB, queue: nil)
    cxProviders.append(p)
    Trace.shared.log("lck.cxProviderCreated")
    return p
  }
  func snapshot(_ label: String, _ m: ConversationManager) {
    Trace.shared.log("lck.snapshot", ["label": label, "conversations": m.conversations.map(LCKTap.describe),
                                      "pending": m.pendingActions.count, "observer": observer.calls.map(describe)])
  }
  func perform(_ m: ConversationManager, _ action: ConversationAction, _ label: String) async {
    let deadline = action.timeoutDate
    let sampled = Date()
    Trace.shared.log("lck.request", ["label": label, "kind": "\(type(of: action))", "action": String(action.uuid.uuidString.prefix(8)),
      "actionID": action.uuid.uuidString, "deadlineMS": Int64(deadline.timeIntervalSince1970 * 1000),
      "sampledAtMS": Int64(sampled.timeIntervalSince1970 * 1000),
      "timeoutIn": (deadline.timeIntervalSince(sampled) * 10).rounded() / 10])
    do { try await m.perform([action]); Trace.shared.log("lck.requestCompleted", ["label": label, "result": "ok"]) }
    catch { Trace.shared.log("lck.requestCompleted", ["label": label, "result": "\(error)"]) }
  }
  // A Focus filters a first report; a repeat from the same number gets through.
  func ring(_ m: ConversationManager, _ label: String, number: String) async -> UUID? {
    for attempt in 1...3 {
      let id = UUID()
      let update = Conversation.Update(members: [Handle(type: .phoneNumber, value: number, displayName: "LCK \(label)")],
                                       capabilities: [.pausing, .playingTones])
      do {
        try await m.reportNewIncomingConversation(uuid: id, update: update)
        Trace.shared.log("lck.reported", ["label": label, "attempt": attempt, "conversation": String(id.uuidString.prefix(8)), "result": "ok"])
        return id
      } catch {
        Trace.shared.log("lck.reported", ["label": label, "attempt": attempt, "result": "\(error)", "nsError": describe(error)])
        await sleep(1)
      }
    }
    return nil
  }
  func incoming(_ m: ConversationManager, _ tag: String) async {
    guard let id = await ring(m, "\(tag)-incoming", number: "+15555550170") else { return }
    await sleep(1.5); snapshot("\(tag)-ringing", m)
    await perform(m, JoinConversationAction(conversationUUID: id), "\(tag)-join")
    await sleep(1.5); snapshot("\(tag)-joined", m)
    await perform(m, MuteConversationAction(conversationUUID: id, isMuted: true), "\(tag)-mute")
    await sleep(0.5)
    await perform(m, PlayToneAction(conversationUUID: id, digits: "12#", tone: .single), "\(tag)-tone")
    await perform(m, PauseConversationAction(conversationUUID: id, isPaused: true), "\(tag)-pause")
    await sleep(1); snapshot("\(tag)-paused", m)
    await perform(m, PauseConversationAction(conversationUUID: id, isPaused: false), "\(tag)-resume")
    await sleep(1)
    await perform(m, EndConversationAction(conversationUUID: id), "\(tag)-end")
    await sleep(1.5); snapshot("\(tag)-ended", m)
  }
  func outgoing(_ m: ConversationManager, _ tag: String) async {
    let id = UUID()
    await perform(m, StartConversationAction(conversationUUID: id, handles: [Handle(type: .phoneNumber, value: "+15555550171")], isVideo: false),
                  "\(tag)-start")
    await sleep(2); snapshot("\(tag)-outgoing", m)
    await perform(m, EndConversationAction(conversationUUID: id), "\(tag)-end")
    await sleep(1.5); snapshot("\(tag)-ended", m)
  }
  func remoteEnd(_ m: ConversationManager, _ tag: String) async {
    guard let id = await ring(m, "\(tag)-incoming", number: "+15555550172") else { return }
    await sleep(1.5)
    if let c = m.conversations.first(where: { $0.uuid == id }) {
      m.reportConversationEvent(.conversationEnded(Date(), .remoteEnded), for: c)
      Trace.shared.log("lck.reportedEnded", ["label": tag])
    }
    await sleep(1.5); snapshot("\(tag)-after-remote-end", m)
  }
  func run() async {
    let scenario = ProcessInfo.processInfo.environment["PROBE_LCK"] ?? "basic"
    observer.setDelegate(self, queue: nil)
    Trace.shared.log("lck.start", ["scenario": scenario, "os": UIDevice.current.systemVersion, "build": osBuild(),
                                   "simulator": ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "device"])
    switch scenario {
    case "basic":
      let m = makeManager(); await sleep(1)
      await outgoing(m, "out")
      await incoming(m, "in")
      await remoteEnd(m, "remote")
    case "cx-after":  // a CXProvider created after the ConversationManager
      let m = makeManager(); await sleep(1); _ = makeProvider(); await sleep(1)
      await outgoing(m, "cxafter-out")
      await incoming(m, "cxafter-in")
    case "lck-after":  // a ConversationManager created after a CXProvider
      _ = makeProvider(); await sleep(1); let m = makeManager(); await sleep(1)
      await outgoing(m, "lckafter-out")
      await incoming(m, "lckafter-in")
    case "echo":
      let m = makeManager(); await sleep(1)
      // Outgoing, so a Focus on the test phone can't filter it.
      let id = UUID()
      await perform(m, StartConversationAction(conversationUUID: id, handles: [Handle(type: .phoneNumber, value: "+15555550174")], isVideo: false), "echo-start")
      await sleep(1.5)
      for delay in [0.0, 0.3, 1.0] {
        LCKTap.muteFulfillDelay = delay
        Trace.shared.log("lck.echoRound", ["delayMs": Int(delay * 1000)])
        await perform(m, MuteConversationAction(conversationUUID: id, isMuted: true), "echo-mute-\(Int(delay * 1000))")
        await sleep(delay + 1.5)
        await perform(m, MuteConversationAction(conversationUUID: id, isMuted: false), "echo-unmute-\(Int(delay * 1000))")
        await sleep(delay + 1.5)
      }
      LCKTap.muteFulfillDelay = 0
      await perform(m, EndConversationAction(conversationUUID: id), "echo-end")
      await sleep(1.5)
    case "two-managers":
      let m1 = makeManager("L1"); await sleep(1); let m2 = makeManager("L2"); await sleep(1)
      await outgoing(m1, "two-m1-out")
      await outgoing(m2, "two-m2-out")
    default:
      Trace.shared.log("lck.unknownScenario", ["scenario": scenario])
    }
    for m in managers { m.invalidate() }
    for p in cxProviders { p.invalidate() }
    await sleep(1)
    Trace.shared.log("done")
    await sleep(0.5)
    exit(0)
  }
}

#endif
