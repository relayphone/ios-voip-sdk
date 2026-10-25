import Foundation

/// The production client/coordinator/intake run against a modeled framework
/// boundary. Request acceptance, handler completion and terminal state are
/// deliberately separate; this does not measure LCK scheduling or device use.
@MainActor private final class ReportControls {
  var endCalls: [UUID] = []
  var startCalls: [UUID] = []
  var held: [UUID: CheckedContinuation<Void, any Error>] = [:]
  var hold: Set<UUID> = []
  var reject: Set<UUID> = []
  var systemEndActions: Set<UUID> = []
  var endedReasons: [UUID: ConversationEndedReason] = [:]
  var waitStage = "existing report contracts"

  func run() async throws {
    let client = try ConversationClient.forApplication(configuration: .init())
    client.finishLaunch()
    let manager = ConversationManager.latest!
    manager.waitForActionSettlement = false
    let observer = client.observeState { update in
      for call in update.conversations {
        if let reason = call.ended?.reason { self.endedReasons[call.id] = reason }
      }
    }
    defer { client.removeStateObserver(observer) }
    client.setConversationHandler(.init(join: { _, _ in }, start: { call, _ in self.startCalls.append(call.id) }, end: { call, context in
      precondition(context.origin == (self.systemEndActions.contains(context.actionID) ? .system : .app))
      self.endCalls.append(call.id)
      if self.reject.contains(call.id) { throw PlatformFailure.rejected }
      if self.hold.contains(call.id) {
        try await withCheckedThrowingContinuation { self.held[call.id] = $0 }
        if self.reject.contains(call.id) { throw PlatformFailure.rejected }
      }
    }))
    func payload(_ value: String) -> IncomingCallPayload {
      .init(eventId: "report-event-" + value, serverCallId: "report-server-" + value,
        caller: .init(id: "report-fixture"))
    }
    func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
      let limit = ContinuousClock.now + .seconds(2)
      while !condition() {
        precondition(ContinuousClock.now < limit, "Report contract observation timed out: " + self.waitStage)
        try await Task.sleep(for: .milliseconds(1))
      }
    }
    func snapshot(_ id: UUID) -> ConversationSnapshot? { client.snapshots.first { $0.id == id } }
    func remove(_ id: UUID) {
      manager.conversations.removeAll { $0.uuid == id }
      client.incomingIntakeDidChange()
    }

    let capacity = NSError(domain: "com.apple.CallKit.error.requesttransaction", code: 7)
    let wrappedCapacity = NSError(domain: "LCK-wrapper", code: 0, userInfo: [NSUnderlyingErrorKey: capacity])
    var tooDeep = capacity
    for _ in 0..<4 { tooDeep = NSError(domain: "wrapper", code: 0, userInfo: [NSUnderlyingErrorKey: tooDeep]) }
    for (error, isCapacity) in [(capacity, true), (wrappedCapacity, true),
      (NSError(domain: "com.apple.CallKit.error.incomingcall", code: 7), false),
      (NSError(domain: "com.apple.CallKit.error.requesttransaction", code: 6), false),
      (NSError(domain: "foreign", code: 7), false), (tooDeep, false)] {
      let before = client.snapshots.map(\.id)
      manager.performError = error
      do {
        _ = try await client.startConversation(to: .init(id: "capacity-control"))
        preconditionFailure("A refused request cannot start a conversation")
      } catch let actual {
        if isCapacity {
          precondition((actual as? ConversationClientError) == .atCapacity,
            "Only requesttransaction/7 must become the typed capacity error")
        } else { precondition((actual as NSError) === error, "Other platform errors must remain unchanged") }
      }
      await Task.yield()
      precondition(client.snapshots.map(\.id) == before && startCalls.isEmpty,
        "Rejected requests must roll back provisional state without invoking a handler")
    }

    let localPayload = payload("local")
    let local = try await client.reportIncomingConversation(localPayload)
    hold.insert(local)
    manager.deferActionDelivery = true
    let reportsBefore = manager.reports.count
    try await client.reportConversation(local, report: .ended(.local))
    let action = manager.appActions.last!
    precondition(action is EndConversationAction && action.conversationUUID == local)
    precondition(endCalls.isEmpty && snapshot(local)?.ended == nil && manager.reports.count == reportsBefore,
      "Accepted local request cannot invent fulfillment, terminal metadata or a remote end")
    manager.deferActionDelivery = false
    manager.deliver(action)
    try await wait { self.held[local] != nil }
    precondition(snapshot(local)?.pending?.kind == .end && snapshot(local)?.ended == nil)
    manager.deferEndedState = true
    hold.remove(local); held.removeValue(forKey: local)?.resume()
    try await wait { action.state == .complete && self.endedReasons[local] == .local }
    precondition(manager.reports.count == reportsBefore && endCalls == [local])
    let explicitAttempts = manager.performAttempts
    manager.incomingErrors = [NSError(domain: "com.apple.CallKit.error.incomingcall", code: 2)]
    _ = try await client.reportIncomingConversation(localPayload, source: .pushKit)
    for _ in 0..<3 { await Task.yield() }
    precondition(manager.performAttempts == explicitAttempts && endCalls == [local] && manager.reports.count == reportsBefore,
      "A required duplicate cannot re-end the same object after an explicit public local End fulfills while terminal membership lags")
    manager.deferEndedState = false

    let requestFailure = try await client.reportIncomingConversation(payload("request-failure"))
    manager.performError = PlatformFailure.rejected
    do {
      try await client.reportConversation(requestFailure, report: .ended(.local))
      preconditionFailure("A rejected command request must reject the report await")
    } catch PlatformFailure.rejected {}
    precondition(snapshot(requestFailure)?.ended == nil && manager.reports.count == reportsBefore)
    try await client.reportConversation(requestFailure, report: .ended(.local))
    let retriedAction = manager.appActions.last!
    try await wait { retriedAction.state == .complete && self.endedReasons[requestFailure] == .local }
    precondition(retriedAction.conversationUUID == requestFailure,
      "A retained cleanup claim cannot suppress an explicit retry after request rejection")
    let handlerFailure = try await client.reportIncomingConversation(payload("handler-failure"))
    reject.insert(handlerFailure)
    try await client.reportConversation(handlerFailure, report: .ended(.local))
    let failedAction = manager.appActions.last!
    try await wait { failedAction.state == .failed }
    precondition(snapshot(handlerFailure)?.ended == nil && manager.reports.count == reportsBefore,
      "A later handler rejection cannot fabricate terminal metadata after request acceptance")
    do {
      try await client.reportConversation(UUID(), report: .ended(.local))
      preconditionFailure("Unknown local request must reject")
    } catch ConversationClientError.unknownConversation {}

    let reasons: [(ConversationEndedReason, Conversation.EndedReason)] = [
      (.remoteEnded, .remoteEnded), (.failed, .failed), (.unanswered, .unanswered),
      (.answeredElsewhere, .joinedElsewhere), (.declinedElsewhere, .declinedElsewhere)]
    for (index, pair) in reasons.enumerated() {
      let id = try await client.reportIncomingConversation(payload("reason-\(index)"))
      try await client.reportConversation(id, report: .ended(pair.0))
      guard case .conversationEnded(_, let actual) = manager.reports.last?.1 else {
        preconditionFailure("Transport termination must use LCK report")
      }
      precondition(actual == pair.1 && manager.reports.last?.0 == id)
    }
    precondition(PushWire.decodeCallEnded(["eventId": "wire-local", "serverCallId": "wire-server", "reason": "local"])?.reason == .remoteEnded,
      "The legacy wire fallback remains remote from the receiver's perspective")
    let wirePayload = payload("wire")
    let wireID = try await client.reportIncomingConversation(wirePayload)
    precondition(!client.receiveCallEnded(.init(eventId: "typed-end", serverCallId: wirePayload.serverCallId, reason: .local)))
    precondition(client.receiveCallEnded(.init(eventId: "typed-end", serverCallId: wirePayload.serverCallId, reason: .declinedElsewhere)),
      "Rejecting typed local cannot poison event dedup")
    guard case .conversationEnded(_, .declinedElsewhere) = manager.reports.last?.1 else { preconditionFailure() }
    precondition(manager.reports.last?.0 == wireID)

    // A new actual object for a retained, locally ended UUID needs a real End
    // request too. No fake local native enum or remote report is available.
    remove(local)
    await Task.yield()
    let attemptsBefore = manager.performAttempts
    let endReportsBefore = manager.reports.count
    hold.insert(local)
    manager.deferEndedState = true
    let repeated = try await client.reportIncomingConversation(localPayload, source: .pushKit)
    precondition(repeated == local)
    try await wait { self.held[local] != nil }
    manager.incomingErrors = [NSError(domain: "com.apple.CallKit.error.incomingcall", code: 2)]
    _ = try await client.reportIncomingConversation(localPayload, source: .pushKit)
    for _ in 0..<3 { await Task.yield() }
    precondition(manager.performAttempts == attemptsBefore + 1,
      "A same-object required duplicate cannot submit another End while the first is pending")
    hold.remove(local); held.removeValue(forKey: local)?.resume()
    try await wait { manager.appActions.last?.state == .complete }
    precondition(endCalls.filter { $0 == local }.count == 2 && manager.reports.count == endReportsBefore)
    manager.incomingErrors = [NSError(domain: "com.apple.CallKit.error.incomingcall", code: 2)]
    _ = try await client.reportIncomingConversation(localPayload, source: .pushKit)
    for _ in 0..<3 { await Task.yield() }
    precondition(manager.performAttempts == attemptsBefore + 1,
      "Accepted End with delayed terminal membership cannot re-end the same object after its local revision changes")
    manager.deferEndedState = false

    // Failure is bounded to one request; it neither relabels history nor retries.
    remove(local)
    await Task.yield()
    manager.performError = PlatformFailure.rejected
    let failedAttempts = manager.performAttempts
    _ = try await client.reportIncomingConversation(localPayload, source: .pushKit)
    try await wait { manager.performAttempts == failedAttempts + 1 }
    for _ in 0..<3 { client.incomingIntakeDidChange(); await Task.yield() }
    precondition(manager.performAttempts == failedAttempts + 1 && snapshot(local)?.ended?.reason == .local &&
      manager.conversations.first(where: { $0.uuid == local })?.state == .idle && manager.reports.count == endReportsBefore)

    manager.incomingErrors = [NSError(domain: "com.apple.CallKit.error.incomingcall", code: 2)]
    _ = try await client.reportIncomingConversation(localPayload, source: .pushKit)
    for _ in 0..<3 { await Task.yield() }
    precondition(manager.performAttempts == failedAttempts + 1,
      "Required duplicate report cannot retry the same failed local terminal request")

    // A queued cleanup must not target an object that replaced its captured one.
    let stale = try await client.reportIncomingConversation(payload("stale"))
    let generation = client.incomingIntake.projection(stale)!.generation
    let original = manager.conversations.first { $0.uuid == stale }!
    client.incomingIntake.terminate(stale, generation: generation, reason: .local)
    let staleAttempts = manager.performAttempts
    client.incomingIntakeDidChange()
    let replacement = Conversation(stale, state: .idle)
    manager.conversations.removeAll { $0.uuid == stale }; manager.conversations.append(replacement)
    for _ in 0..<3 { await Task.yield() }
    precondition(manager.performAttempts == staleAttempts && replacement.state == .idle)

    // No pending bit remains after the skipped task. The observed replacement
    // still owns the same canonical local termination and needs its first End.
    manager.deferEndedState = true
    client.incomingIntakeDidChange()
    waitStage = "replacement B first End"
    try await wait { manager.performAttempts == staleAttempts + 1 && manager.appActions.last?.state == .complete }
    precondition(endCalls.filter { $0 == stale }.count == 1 && replacement.state == .idle)
    manager.conversations.removeAll { $0.uuid == stale }; manager.conversations.append(original)
    client.incomingIntakeDidChange()
    waitStage = "skipped A first End"
    try await wait { manager.performAttempts == staleAttempts + 2 && manager.appActions.last?.state == .complete }
    precondition(endCalls.filter { $0 == stale }.count == 2,
      "An object skipped before submission remains eligible for its first request")
    for object in [replacement, original, replacement] {
      manager.conversations.removeAll { $0.uuid == stale }; manager.conversations.append(object)
      client.incomingIntakeDidChange()
      for _ in 0..<3 { await Task.yield() }
      precondition(manager.performAttempts == staleAttempts + 2,
        "Weak claim history must suppress repeated requests through A/B/A object observations")
    }
    remove(stale)
    // Observe queued record cleanup; executor scheduling has no fixed delay.
    // Canonical intake and the deliberately retained objects outlive that cache.
    waitStage = "retained object actor record cleanup"
    try await wait { snapshot(stale) == nil }
    precondition(snapshot(stale) == nil && client.incomingIntake.projection(stale)?.generation == generation)
    manager.conversations.append(replacement)
    client.incomingIntakeDidChange()
    for _ in 0..<3 { await Task.yield() }
    precondition(manager.performAttempts == staleAttempts + 2 && snapshot(stale)?.ended?.reason == .local,
      "Actor record removal cannot discard a still-live generation/object submission claim")
    // A reset retires the old generation. The same modeled framework object can
    // have its first request in a new local generation; old claims cannot block it.
    manager.conversations.removeAll { $0.uuid != stale }
    client.incomingIntake.reset()
    let nextGeneration = client.incomingIntake.projection(stale)!.generation
    precondition(nextGeneration != generation)
    client.incomingIntake.terminate(stale, generation: nextGeneration, reason: .local)
    client.incomingIntakeDidChange()
    waitStage = "new generation same object first End"
    try await wait {
      let actions = manager.appActions.filter { $0.conversationUUID == stale }
      return actions.count == 3 && actions.last?.state == .complete
    }
    manager.deferEndedState = false

    let revised = try await client.reportIncomingConversation(payload("revised"))
    let revisedGeneration = client.incomingIntake.projection(revised)!.generation
    client.incomingIntake.terminate(revised, generation: revisedGeneration, reason: .local)
    let revisedAttempts = manager.performAttempts
    client.incomingIntakeDidChange()
    client.incomingIntake.terminate(revised, generation: revisedGeneration, reason: .failed, requiresReport: false)
    for _ in 0..<3 { await Task.yield() }
    precondition(manager.performAttempts == revisedAttempts, "A newer terminal revision must invalidate queued local cleanup")
    client.incomingIntake.terminate(revised, generation: revisedGeneration, reason: .local)
    client.incomingIntakeDidChange()
    waitStage = "new revision after unsubmitted stale task"
    try await wait { manager.performAttempts == revisedAttempts + 1 && manager.appActions.last?.state == .complete }

    let reset = try await client.reportIncomingConversation(payload("reset"))
    client.incomingIntake.terminate(reset, generation: client.incomingIntake.projection(reset)!.generation, reason: .local)
    let resetAttempts = manager.performAttempts
    client.incomingIntakeDidChange()
    client.incomingIntake.reset()
    for _ in 0..<3 { await Task.yield() }
    precondition(manager.performAttempts == resetAttempts, "Reset invalidation must stop queued old-generation cleanup")

    // A genuine system End is already an attempt for this object. Retained
    // cleanup must not submit an app End while that same system action is held.
    // Keep its claim on rejection too, matching app-attempt policy; a deliberate
    // public retry remains independent of automatic cleanup suppression.
    func heldSystemEndWithRetainedLocal(_ value: String, rejecting: Bool) async throws {
      let id = try await client.reportIncomingConversation(payload(value))
      let generation = client.incomingIntake.projection(id)!.generation
      client.incomingIntake.terminate(id, generation: generation, reason: .local)
      hold.insert(id)
      manager.deferEndedState = true
      let attempts = manager.performAttempts
      let reports = manager.reports.count
      let action = EndConversationAction(conversationUUID: id)
      systemEndActions.insert(action.uuid)
      manager.deliver(action)
      waitStage = value + " held genuine system End"
      try await wait { self.held[id] != nil }
      for _ in 0..<3 { await Task.yield() }
      precondition(manager.performAttempts == attempts && endCalls.filter { $0 == id }.count == 1,
        "Retained local cleanup must not submit an automatic app End while the same object has a pending system End")
      precondition(action.state == .running && action.settlements == 0 && manager.reports.count == reports)
      if rejecting { reject.insert(id) }
      hold.remove(id); held.removeValue(forKey: id)?.resume()
      waitStage = value + " genuine system End settlement"
      try await wait { action.state == (rejecting ? .failed : .complete) }
      reject.remove(id)
      precondition(action.settlements == 1 && manager.reports.count == reports)
      for _ in 0..<3 { client.incomingIntakeDidChange(); await Task.yield() }
      precondition(manager.performAttempts == attempts && endCalls.filter { $0 == id }.count == 1,
        "An observed system attempt retains its same-object claim after acceptance or rejection")
      if rejecting {
        try await client.reportConversation(id, report: .ended(.local))
        let retry = manager.appActions.last!
        waitStage = value + " explicit retry after rejected system End"
        try await wait { retry.state == .complete }
        precondition(manager.performAttempts == attempts + 1 && retry.conversationUUID == id &&
          endCalls.filter { $0 == id }.count == 2 && manager.reports.count == reports,
          "Retained automatic cleanup claims cannot suppress an explicit retry after system rejection")
      }
      manager.deferEndedState = false
    }
    try await heldSystemEndWithRetainedLocal("system-retained-local-accepted", rejecting: false)
    try await heldSystemEndWithRetainedLocal("system-retained-local-rejected", rejecting: true)

    // Replacement is synchronous while A's handler is held. No observation or
    // scheduler ordering can submit B before A's completion accounting runs.
    func completionAfterReplacement(_ value: String, system: Bool) async throws {
      let id = try await client.reportIncomingConversation(payload(value))
      let original = manager.conversations.first { $0.uuid == id }!
      hold.insert(id)
      manager.deferEndedState = true
      let attempts = manager.performAttempts
      let first: ConversationAction
      if system {
        let action = EndConversationAction(conversationUUID: id)
        systemEndActions.insert(action.uuid)
        manager.deliver(action)
        first = action
      } else {
        try await client.reportConversation(id, report: .ended(.local))
        first = manager.appActions.last!
      }
      waitStage = value + " original held End"
      try await wait { self.held[id] != nil }
      let replacement = Conversation(id, state: .idle)
      manager.conversations.removeAll { $0.uuid == id }; manager.conversations.append(replacement)
      hold.remove(id); held.removeValue(forKey: id)?.resume()
      try await wait { first.state == .complete }
      client.incomingIntakeDidChange()
      let expectedAttempts = attempts + (system ? 1 : 2)
      waitStage = value + " replacement first End"
      try await wait {
        manager.performAttempts == expectedAttempts &&
          manager.appActions.last?.conversationUUID == id && manager.appActions.last?.state == .complete
      }
      precondition(endCalls.filter { $0 == id }.count == 2 && replacement.state == .idle,
        "A's accepted End cannot claim B without B's own submission")
      manager.conversations.removeAll { $0.uuid == id }; manager.conversations.append(original)
      client.incomingIntakeDidChange()
      for _ in 0..<3 { await Task.yield() }
      precondition(manager.performAttempts == expectedAttempts,
        "Completion accounting must retain A's original generation/object claim")
      manager.deferEndedState = false
    }
    try await completionAfterReplacement("app-completion-replacement", system: false)
    try await completionAfterReplacement("system-completion-replacement", system: true)

    let heldReset = try await client.reportIncomingConversation(payload("held-reset"))
    hold.insert(heldReset)
    try await client.reportConversation(heldReset, report: .ended(.local))
    let oldAction = manager.appActions.last!
    waitStage = "held End before real manager reset"
    try await wait { self.held[heldReset] != nil }
    let oldGeneration = client.incomingIntake.projection(heldReset)!.generation
    manager.delegate?.conversationManagerDidReset(manager)
    let newProjection = client.incomingIntake.projection(heldReset)!
    precondition(newProjection.generation != oldGeneration && oldAction.state == .failed)
    hold.remove(heldReset); held.removeValue(forKey: heldReset)?.resume()
    for _ in 0..<3 { await Task.yield() }
    precondition(oldAction.settlements == 1 &&
      client.incomingIntake.projection(heldReset)?.terminal == newProjection.terminal,
      "A real reset cancels delivered old-generation End before late completion can mutate its replacement")
    precondition(held.isEmpty)
    print("{\"success\":true,\"groups\":26,\"actualClientAndCoordinatorAndIntake\":true,\"nativeFrameworkMeasured\":false}")
  }
}

@main struct ReportContractTests {
  @MainActor static func main() async throws { try await ReportControls().run() }
}
