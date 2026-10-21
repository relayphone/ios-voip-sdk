import AVFoundation
import LiveCommunicationKit
import SwiftUI

func log(_ event: String, _ detail: String = "") {
  FileHandle.standardError.write(Data("LCK \(Int(Date().timeIntervalSince(Probe.t0) * 1000)) \(event) \(detail)\n".utf8))
}

final class Probe: ConversationManagerDelegate, @unchecked Sendable {
  static let t0 = Date()
  let manager: ConversationManager
  init() {
    let config = ConversationManager.Configuration(ringtoneName: nil, iconTemplateImageData: nil, maximumConversationGroups: 1,
      maximumConversationsPerConversationGroup: 1, includesConversationInRecents: false, supportsVideo: false, supportedHandleTypes: [.phoneNumber])
    manager = ConversationManager(configuration: config)
    manager.delegate = self
  }
  func conversationManager(_ manager: ConversationManager, conversationChanged conversation: Conversation) {
    log("conversationChanged", "\(conversation.state)")
  }
  func conversationManagerDidBegin(_ manager: ConversationManager) { log("didBegin") }
  func conversationManagerDidReset(_ manager: ConversationManager) { log("didReset") }
  func conversationManager(_ manager: ConversationManager, perform action: ConversationAction) {
    log("perform", "\(type(of: action))"); action.fulfill()
  }
  func conversationManager(_ manager: ConversationManager, timedOutPerforming action: ConversationAction) { log("timedOut", "\(type(of: action))") }
  func conversationManager(_ manager: ConversationManager, didActivate audioSession: AVAudioSession) { log("didActivate") }
  func conversationManager(_ manager: ConversationManager, didDeactivate audioSession: AVAudioSession) { log("didDeactivate") }
  func run() async {
    log("start", "CXProvider instances via LCK? watch CKSIM lines")
    let id = UUID()
    do {
      try await manager.reportNewIncomingConversation(uuid: id, update: Conversation.Update(members: [Handle(type: .phoneNumber, value: "+15555550100", displayName: "LCK Caller")]))
      log("reported", "ok")
    } catch { log("reported", "error \(error)") }
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    log("conversations", "\(manager.conversations.map { "\($0.state)" })")
    if let c = manager.conversations.first {
      do { try await manager.perform([JoinConversationAction(conversationUUID: c.uuid)]); log("join", "ok") } catch { log("join", "error \(error)") }
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      log("conversations", "\(manager.conversations.map { "\($0.state)" })")
      do { try await manager.perform([EndConversationAction(conversationUUID: c.uuid)]); log("end", "ok") } catch { log("end", "error \(error)") }
    }
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    log("done")
  }
}

@main
struct LCKApp: App {
  static let probe = Probe()
  var body: some Scene { WindowGroup { Text("LCK probe").task { await LCKApp.probe.run() } } }
}
