import Foundation

@MainActor
private final class ContractControls {
  let client = HostClientOwner.acquire()
  var manager: ConversationManager { ConversationManager.latest! }
  var endWork: CheckedContinuation<Void, any Error>?
  var endCalls = 0

  func snapshot(_ id: UUID) -> ConversationSnapshot { client.snapshots.first { $0.id == id }! }
  func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
    let limit = ContinuousClock.now + .seconds(2)
    while !condition() {
      precondition(ContinuousClock.now < limit, "Client contract boundary timed out")
      try await Task.sleep(for: .milliseconds(1))
    }
  }
  func payload(_ suffix: String) -> IncomingCallPayload {
    .init(eventId: "contract-event-" + suffix, serverCallId: "contract-server-" + suffix,
      caller: .init(id: "host-contract-caller"))
  }
  func run() async throws {
    client.setConversationHandler(.init(join: { _, _ in }, start: { _, _ in }, end: { [weak self] _, context in
      guard let self else { preconditionFailure("Control owner vanished") }
      precondition(context.origin == .app)
      self.endCalls += 1
      try await withCheckedThrowingContinuation { self.endWork = $0 }
    }))
    let incoming = try await client.reportIncomingConversation(payload("incoming"))
    precondition(snapshot(incoming).status == .ringing && snapshot(incoming).connectedAt == nil)
    try await client.joinConversation(incoming)
    precondition(snapshot(incoming).status == .connecting && snapshot(incoming).pending == nil &&
      snapshot(incoming).connectedAt == nil, "Incoming join accepts signaling; only a backend connected report connects")
    let outgoing = try await client.startConversation(to: .init(id: "host-contract-recipient"))
    precondition(snapshot(outgoing).status == .dialing && snapshot(outgoing).pending == nil &&
      snapshot(outgoing).connectedAt == nil, "Outgoing fulfilled Start may stay idle/dialing; it cannot fabricate transport connection")
    for id in [incoming, outgoing] {
      try await client.reportConversation(id, report: .connecting)
      precondition(snapshot(id).status == .connecting && snapshot(id).connectedAt == nil)
      try await client.reportConversation(id, report: .connected)
      precondition(snapshot(id).status == .connected && snapshot(id).connectedAt != nil)
    }

    let before = manager.reports.count
    var terminalReasons: [ConversationEndedReason] = []
    let observer = client.observeState { update in
      if let reason = update.conversations.first(where: { $0.id == incoming })?.ended?.reason {
        terminalReasons.append(reason)
      }
    }
    defer { client.removeStateObserver(observer) }
    var completed = false
    let local = Task { try await self.client.reportConversation(incoming, report: .ended(.local)); completed = true }
    try await wait { self.endWork != nil }
    precondition(!completed && endCalls == 1 && manager.appActions.last is EndConversationAction &&
      manager.reports.count == before && snapshot(incoming).ended == nil,
      "Local report must await a public End action and cannot report remote end or premature metadata")
    endWork?.resume(); endWork = nil
    try await local.value
    precondition(completed && manager.reports.count == before && terminalReasons.contains(.local),
      "Local end succeeds through its command; no remote report may be sent")

    let failedID = try await client.startConversation(to: .init(id: "host-rejected-end"))
    let rejected = Task { try await self.client.reportConversation(failedID, report: .ended(.local)) }
    try await wait { self.endWork != nil }
    endWork?.resume(throwing: PlatformFailure.rejected); endWork = nil
    do { try await rejected.value; preconditionFailure("Rejected local end must reject its report promise") }
    catch PlatformFailure.rejected {}
    precondition(snapshot(failedID).ended == nil && manager.reports.count == before,
      "Rejected local end must preserve live metadata and avoid a false remote-ended report")

    let reasons: [(ConversationEndedReason, Conversation.EndedReason)] = [
      (.remoteEnded, .remoteEnded), (.failed, .failed), (.unanswered, .unanswered),
      (.answeredElsewhere, .joinedElsewhere), (.declinedElsewhere, .declinedElsewhere)]
    for (index, pair) in reasons.enumerated() {
      let id = try await client.reportIncomingConversation(payload("ended-\(index)"))
      try await client.reportConversation(id, report: .ended(pair.0))
      guard case .conversationEnded(_, let reason) = manager.reports.last?.1 else {
        preconditionFailure("Transport end must use the actual LCK report API")
      }
      precondition(manager.reports.last?.0 == id && reason == pair.1)
    }
    let wire = ["eventId": "wire-local", "serverCallId": "contract-server-incoming", "reason": "local"]
    precondition(PushWire.decodeCallEnded(wire)?.reason == .remoteEnded,
      "Legacy wire fallback stays unchanged: a peer's local hangup is remote here")
    manager.pauseIncoming = true
    let pending = Task { try await self.client.reportIncomingConversation(self.payload("pending-end")) }
    try await wait { self.manager.incomingWork != nil }
    let remoteReportCount = manager.reports.count
    precondition(!client.receiveCallEnded(.init(eventId: "same-native-end", serverCallId: "contract-server-pending-end", reason: .local)),
      "Native callEnded refuses local before queuing a deferred remote report")
    precondition(client.receiveCallEnded(.init(eventId: "same-native-end", serverCallId: "contract-server-pending-end", reason: .remoteEnded)),
      "Refusing local must not poison event dedup for a real transport termination")
    precondition(manager.reports.count == remoteReportCount, "Remote end waits for the actual incoming report")
    manager.incomingWork?.resume(); manager.incomingWork = nil; manager.pauseIncoming = false
    let pendingID = try await pending.value
    guard case .conversationEnded(_, .remoteEnded) = manager.reports.last?.1 else {
      preconditionFailure("Deferred remote end lost its correct native reason")
    }
    precondition(manager.reports.last?.0 == pendingID && endCalls == 2)
    try await duplicateReportErrors()
    print("{\"success\":true,\"groups\":10,\"actualClientAndHandler\":true,\"nativeFrameworkMeasured\":false}")
  }

  func duplicateReportErrors() async throws {
    let invitation = payload("duplicate-errors")
    let live = try await client.reportIncomingConversation(invitation)
    let duplicate = NSError(domain: "com.apple.CallKit.error.incomingcall", code: 2)
    // Representative framework-boundary NSError wrapping. The production
    // classifier and Client catch/rollback paths run unchanged; this is not a
    // measurement of the genuine framework's wrapper shape.
    func wrapped(_ error: NSError) -> NSError {
      NSError(domain: "host.lck-boundary", code: 1, userInfo: [NSUnderlyingErrorKey: error])
    }
    for error in [duplicate, wrapped(wrapped(duplicate))] {
      let attempts = manager.reportedIncoming.count
      manager.incomingErrors = [error]
      let id = try await client.reportIncomingConversation(invitation, source: .pushKit)
      precondition(id == live && manager.reportedIncoming.count == attempts + 1 &&
        manager.reportedIncoming.last == live && manager.conversations.filter { $0.uuid == live }.count == 1,
        "Each delivery must make its own report; a known-live duplicate may be accepted without a second conversation")
    }
    let negatives = [NSError(domain: duplicate.domain, code: 3),
      NSError(domain: "unrelated.domain", code: 2), wrapped(NSError(domain: duplicate.domain, code: 4))]
    for expected in negatives {
      manager.incomingErrors = [expected]
      do {
        _ = try await client.reportIncomingConversation(invitation, source: .pushKit)
        preconditionFailure("A nonduplicate report failure must propagate")
      } catch {
        let actual = error as NSError
        precondition(actual.domain == expected.domain && actual.code == expected.code,
          "Report rejection must preserve the actual boundary error")
      }
      precondition(snapshot(live).payload == invitation && manager.conversations.filter { $0.uuid == live }.count == 1,
        "A failed repeated report must preserve existing live metadata")
    }
    let fresh = payload("not-yet-reported")
    manager.incomingErrors = [wrapped(duplicate)]
    do {
      _ = try await client.reportIncomingConversation(fresh, source: .pushKit)
      preconditionFailure("Duplicate-shaped error cannot prove a never-reported conversation exists")
    } catch {
      precondition((error as NSError).domain == "host.lck-boundary")
    }
    let failedID = manager.reportedIncoming.last!
    let retry = try await client.reportIncomingConversation(fresh)
    precondition(retry != failedID && snapshot(retry).payload == fresh,
      "A genuinely unreported failure must roll metadata/dedup back for a fresh retry")
  }
}

@main struct ClientContractTests {
  @MainActor static func main() async throws { try await ContractControls().run() }
}
