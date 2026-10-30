import Foundation

/// Whole-client signaling/connection projection at a modeled LCK boundary.
@main struct ConnectionContractTests {
  @MainActor static func main() async throws {
    let client = try ConversationClient.forApplication(configuration: .init())
    client.finishLaunch()
    let manager = ConversationManager.latest!
    client.setConversationHandler(.init(join: { _, _ in }, start: { _, _ in }, end: { _, _ in }))
    func snapshot(_ id: UUID) -> ConversationSnapshot { client.snapshots.first { $0.id == id }! }
    func platformState(_ id: UUID, _ state: Conversation.State) {
      let conversation = manager.conversations.first { $0.uuid == id }!
      conversation.state = state
      client.conversationManager(manager, conversationChanged: conversation)
    }
    let incoming = try await client.reportIncomingConversation(.init(eventID: "connection-event",
      serverCallID: .init(rawValue: "connection-server"), caller: try! Caller(handleType: .generic, value: "connection-caller", displayName: "connection-caller")))
    precondition(snapshot(incoming).status == .ringing && snapshot(incoming).connectedAt == nil)
    try await client.joinConversation(incoming)
    precondition(snapshot(incoming).status == .connecting && snapshot(incoming).pending == nil &&
      snapshot(incoming).connectedAt == nil, "Accepted incoming signaling cannot fabricate transport connection")
    let outgoing = try await client.startConversation(to: .init(id: "connection-recipient"))
    precondition(snapshot(outgoing).status == .dialing && snapshot(outgoing).pending == nil && snapshot(outgoing).connectedAt == nil,
      "Fulfilled outgoing Start can remain idle/dialing until the transport reports progress")
    for id in [incoming, outgoing] {
      try await client.reportConversation(id, report: .connecting)
      precondition(snapshot(id).status == .connecting && snapshot(id).connectedAt == nil)
      platformState(id, .paused)
      precondition(snapshot(id).status == .held && snapshot(id).connectedAt == nil)
      platformState(id, .joined)
      precondition(snapshot(id).status == .connecting && snapshot(id).connectedAt == nil)
      try await client.reportConversation(id, report: .connected)
      precondition(snapshot(id).status == .connected && snapshot(id).connectedAt != nil)
      let timestamp = snapshot(id).connectedAt
      platformState(id, .paused)
      precondition(snapshot(id).status == .held && snapshot(id).connectedAt == timestamp)
      platformState(id, .joined)
      precondition(snapshot(id).status == .connected && snapshot(id).connectedAt == timestamp)
      platformState(id, .leaving)
      precondition(snapshot(id).status == .ending)
      platformState(id, .left)
      precondition(snapshot(id).status == .ended)
    }
    print("{\"success\":true,\"groups\":7,\"actualClientAndCoordinator\":true,\"nativeFrameworkMeasured\":false}")
  }
}
