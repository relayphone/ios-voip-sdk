import Foundation

/// The production client/coordinator/intake run against a modeled framework
/// boundary. Request acceptance, handler completion and terminal state are
/// deliberately separate; this does not measure LCK scheduling or device use.
@MainActor private final class ReportControls {
  var endCalls: [UUID] = []
  var startCalls: [UUID] = []
  var endSnapshots: [UUID: ConversationSnapshot] = [:]
  var endContexts: [UUID: [ConversationActionContext]] = [:]
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
    let handler = ConversationHandler(join: { _, _ in }, start: { call, _ in self.startCalls.append(call.id) }, end: { call, context in
      precondition(context.origin == (self.systemEndActions.contains(context.actionID) ? .system : .app))
      self.endCalls.append(call.id)
      self.endSnapshots[context.actionID] = call
      self.endContexts[context.actionID, default: []].append(context)
      if self.reject.contains(call.id) { throw PlatformFailure.rejected }
      if self.hold.contains(call.id) {
        try await withCheckedThrowingContinuation { self.held[call.id] = $0 }
        if self.reject.contains(call.id) { throw PlatformFailure.rejected }
      }
    })
    client.setConversationHandler(handler)
    func payload(_ value: String) -> IncomingCallPayload {
      .init(eventId: "report-event-" + value, serverCallId: "report-server-" + value,
        caller: try! Caller(handleType: .generic, value: "report-fixture", displayName: "report-fixture"))
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

    // Explicit backend ownership ends ringing without waiting for an End handler.
    let elsewherePayload = payload("answered-elsewhere")
    let elsewhereID = try await client.reportIncomingConversation(elsewherePayload)
    var elsewhereEvents: [ConversationEventContext] = []
    var stateAtElsewhereEvent: ConversationSnapshot?
    let elsewhereObserver = client.observeEvents { event in
      if event.type == .answeredElsewhere {
        elsewhereEvents.append(event); stateAtElsewhereEvent = snapshot(event.conversationID!)
      }
    }
    let elsewhereAttempts = manager.performAttempts
    let elsewhereSignal = CallEndedPayload(eventId: "answered-signal", serverCallId: elsewherePayload.serverCallId,
      reason: .answeredElsewhere)
    precondition(client.receiveCallEnded(elsewhereSignal))
    guard case .conversationEnded(_, .joinedElsewhere) = manager.reports.last?.1 else { preconditionFailure() }
    precondition(manager.reports.last?.0 == elsewhereID && manager.performAttempts == elsewhereAttempts)
    precondition(elsewhereEvents.count == 1 && elsewhereEvents[0].conversationID == elsewhereID &&
      elsewhereEvents[0].serverCallID == elsewherePayload.serverCallId && elsewhereEvents[0].eventID == "answered-signal")
    precondition(stateAtElsewhereEvent?.ended?.reason == .answeredElsewhere && stateAtElsewhereEvent?.status == .ended)
    precondition(!client.receiveCallEnded(elsewhereSignal) && elsewhereEvents.count == 1)
    precondition(!client.receiveCallEnded(.init(eventId: "unknown-answered", serverCallId: "unknown", reason: .answeredElsewhere)))
    precondition(!client.receiveCallEnded(.init(eventId: "", serverCallId: elsewherePayload.serverCallId, reason: .answeredElsewhere)))

    let pairedA = payload("answered-paired-a"), pairedB = payload("answered-paired-b")
    let pairedAID = try await client.reportIncomingConversation(pairedA)
    let pairedBID = try await client.reportIncomingConversation(pairedB)
    var pairedBSignalled = false
    let pairedState = client.observeState { update in
      if !pairedBSignalled && update.conversations.contains(where: { $0.id == pairedAID && $0.status == .ended }) {
        pairedBSignalled = true
        precondition(client.receiveCallEnded(.init(eventId: "paired-b", serverCallId: pairedB.serverCallId, reason: .answeredElsewhere)))
      }
    }
    var pairedEvents: [UUID: Int] = [:]
    let pairedObserver = client.observeEvents { event in
      if event.type == .answeredElsewhere, let id = event.conversationID, [pairedAID, pairedBID].contains(id) {
        pairedEvents[id, default: 0] += 1
        client.incomingIntakeDidChange() // Reenter while another ready event is pending.
      }
    }
    precondition(client.receiveCallEnded(.init(eventId: "paired-a", serverCallId: pairedA.serverCallId, reason: .answeredElsewhere)))
    precondition(pairedBSignalled && pairedEvents == [pairedAID: 1, pairedBID: 1],
      "Reentrant state/event observers cannot drain a pending ownership event twice")
    client.removeStateObserver(pairedState); client.removeEventObserver(pairedObserver)

    let workerPayload = payload("answered-worker-window")
    let workerID = try await client.reportIncomingConversation(workerPayload)
    let workerObject = manager.conversations.first { $0.uuid == workerID }!
    // Model the supported worker-to-intake delivery precisely between the
    // actor's projection read and pending-termination claim at the LCK boundary.
    workerObject.onNextStateRead = {
      precondition(client.incomingIntake.terminate(.init(eventId: "worker-signal",
        serverCallId: workerPayload.serverCallId, reason: .answeredElsewhere)))
    }
    client.incomingIntakeDidChange()
    precondition(workerObject.state == .left && elsewhereEvents.filter { $0.conversationID == workerID }.count == 1,
      "A worker termination after projection capture cannot lose the SDK event")

    // A report already in flight can publish a fresh ringing object after the
    // first platform object has consumed the pending termination bit.
    let racingPayload = payload("answered-race")
    let racingID = try await client.reportIncomingConversation(racingPayload)
    manager.pauseIncoming = true
    let racingReport = Task { @MainActor in try await client.reportIncomingConversation(racingPayload, source: .pushKit) }
    waitStage = "answered elsewhere duplicate report pending"
    try await wait { manager.incomingWork != nil }
    precondition(client.receiveCallEnded(.init(eventId: "race-answer", serverCallId: racingPayload.serverCallId,
      reason: .answeredElsewhere)))
    let reportsForA = manager.reports.filter { $0.0 == racingID }.count
    manager.conversations.removeAll { $0.uuid == racingID }
    manager.pauseIncoming = false; manager.incomingWork?.resume(); manager.incomingWork = nil
    let racingResult = try await racingReport.value
    precondition(racingResult == racingID)
    precondition(manager.conversations.first { $0.uuid == racingID }?.state == .left,
      "Retained answered-elsewhere must end the later actual ringing object")
    precondition(manager.reports.filter { $0.0 == racingID }.count == reportsForA + 1)
    precondition(elsewhereEvents.filter { $0.conversationID == racingID }.count == 1,
      "Ending a replacement object cannot duplicate the ownership event")

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

    // A queued terminal cleanup and a later stale .left callback must leave a
    // current same-UUID replacement authoritative, including its pending End.
    let reused = try await client.reportIncomingConversation(payload("terminal-replacement"))
    let retired = manager.conversations.first { $0.uuid == reused }!
    retired.state = .left
    manager.conversations.removeAll { $0 === retired }
    manager.delegate?.conversationManager(manager, conversationChanged: retired)
    precondition(snapshot(reused)?.status == .ended)
    let replacementAfterLeft = Conversation(reused, state: .idle)
    manager.conversations.append(replacementAfterLeft)
    client.incomingIntakeDidChange()
    hold.insert(reused)
    let replacementEnd = EndConversationAction(conversationUUID: reused)
    systemEndActions.insert(replacementEnd.uuid)
    manager.deliver(replacementEnd)
    waitStage = "replacement End after old terminal delegate"
    try await wait { self.held[reused] != nil }
    let replacementState = client.state
    manager.delegate?.conversationManager(manager, conversationChanged: retired)
    for _ in 0..<3 { await Task.yield() }
    precondition(manager.conversations.first { $0.uuid == reused } === replacementAfterLeft &&
      replacementAfterLeft.state == .idle && client.state == replacementState &&
      snapshot(reused)?.pending?.id == replacementEnd.uuid && replacementEnd.state == .running &&
      replacementEnd.settlements == 0 && endSnapshots[replacementEnd.uuid]?.status == .ringing,
      "Old terminal projection cleanup cannot replace the current object's handler input or cancel its pending End")
    hold.remove(reused); held.removeValue(forKey: reused)?.resume()
    waitStage = "replacement End settlement"
    try await wait { replacementEnd.state == .complete }
    precondition(replacementEnd.settlements == 1 && endCalls.filter { $0 == reused }.count == 1)
    remove(reused)
    waitStage = "replacement public state removal"
    try await wait { snapshot(reused) == nil }

    // ha-fail-join and ha-fail-pause publish .left before the genuine cleanup
    // End (5 and 16 ms later). Keep the SAME native object alive but absent from
    // manager membership, and let the next-turn public projection cleanup run.
    // LCK's End callback carries its UUID only; no replacement is introduced.
    let cleanupPayload = payload("system-end-after-left")
    let cleanupID = try await client.reportIncomingConversation(cleanupPayload)
    let terminalOriginal = manager.conversations.first { $0.uuid == cleanupID }!
    defer { withExtendedLifetime(terminalOriginal) {} }
    terminalOriginal.state = .left
    manager.conversations.removeAll { $0 === terminalOriginal }
    manager.delegate?.conversationManager(manager, conversationChanged: terminalOriginal)
    precondition(snapshot(cleanupID)?.status == .ended && snapshot(cleanupID)?.payload == cleanupPayload,
      "The original native terminal callback must first publish its actual terminal snapshot")
    waitStage = "original terminal public projection cleanup before system End"
    try await wait { snapshot(cleanupID) == nil }
    let stateAfterLeft = client.state
    let attemptsAfterLeft = manager.performAttempts
    let reportsAfterLeft = manager.reports.count
    let cleanupEnd = EndConversationAction(conversationUUID: terminalOriginal.uuid)
    systemEndActions.insert(cleanupEnd.uuid)
    precondition(manager.conversations.allSatisfy { $0.uuid != cleanupID } && terminalOriginal.state == .left)
    manager.deliver(cleanupEnd)
    waitStage = "genuine system End after original terminal projection cleanup"
    try await wait { cleanupEnd.state == .complete || cleanupEnd.state == .failed }
    for _ in 0..<3 { await Task.yield() }
    precondition(client.state == stateAfterLeft && snapshot(cleanupID) == nil &&
      manager.performAttempts == attemptsAfterLeft && manager.reports.count == reportsAfterLeft &&
      manager.conversations.allSatisfy { $0.uuid != cleanupID } && terminalOriginal.state == .left,
      "A late cleanup End cannot recreate public state, request another End, or report a fabricated transition")
    let cleanupHandlerCalls = endCalls.filter { $0 == cleanupID }.count
    precondition(cleanupHandlerCalls == 1 && endSnapshots[cleanupEnd.uuid]?.status == .ended &&
      endSnapshots[cleanupEnd.uuid]?.payload == cleanupPayload,
      "A genuine system End after .left must invoke application cleanup once with the original terminal input; calls=\(cleanupHandlerCalls), settlements=\(cleanupEnd.settlements), complete=\(cleanupEnd.state == .complete)")
    precondition(cleanupEnd.state == .complete && cleanupEnd.settlements == 1,
      "Application cleanup success must fulfill the genuine platform End exactly once")

    func departedOriginal(_ value: String) async throws -> (UUID, Conversation) {
      let id = try await client.reportIncomingConversation(payload(value))
      let original = manager.conversations.first { $0.uuid == id }!
      original.state = .left
      manager.conversations.removeAll { $0 === original }
      manager.delegate?.conversationManager(manager, conversationChanged: original)
      waitStage = value + " terminal public cleanup"
      try await wait { snapshot(id) == nil }
      return (id, original)
    }
    func systemEnd(_ id: UUID) -> EndConversationAction {
      let action = EndConversationAction(conversationUUID: id)
      systemEndActions.insert(action.uuid)
      manager.deliver(action)
      return action
    }

    // Handler installation and reload retain action-local terminal input and
    // the same effective deadline, without publishing the pending action.
    let (attachID, attachOriginal) = try await departedOriginal("terminal-handler-reload")
    defer { withExtendedLifetime(attachOriginal) {} }
    hold.insert(attachID)
    client.setConversationHandler(nil)
    let attachState = client.state
    let attachEnd = systemEnd(attachID)
    for _ in 0..<3 { await Task.yield() }
    precondition(attachEnd.state == .running && attachEnd.settlements == 0 &&
      endContexts[attachEnd.uuid] == nil && client.state == attachState,
      "A real terminal cleanup End remains pending until a handler attaches")
    client.setConversationHandler(handler)
    waitStage = "late terminal handler attachment"
    try await wait { self.held[attachID] != nil }
    let firstContext = endContexts[attachEnd.uuid]!.first!
    let oldContinuation = held.removeValue(forKey: attachID)!
    client.setConversationHandler(handler)
    waitStage = "terminal handler reload redelivery"
    try await wait { self.held[attachID] != nil && self.endContexts[attachEnd.uuid]?.count == 2 }
    let nextContext = endContexts[attachEnd.uuid]!.last!
    precondition(firstContext.signal.reason == .replaced && !nextContext.signal.isCancelled &&
      nextContext.actionID == firstContext.actionID && nextContext.origin == .system &&
      nextContext.deadline == firstContext.deadline &&
      endSnapshots[attachEnd.uuid]?.pending?.id == attachEnd.uuid &&
      endSnapshots[attachEnd.uuid]?.pending?.deadline == nextContext.deadline && client.state == attachState)
    oldContinuation.resume()
    for _ in 0..<3 { await Task.yield() }
    precondition(attachEnd.state == .running && attachEnd.settlements == 0,
      "A cancelled handler delivery cannot settle the reloaded cleanup action")
    hold.remove(attachID); held.removeValue(forKey: attachID)?.resume()
    waitStage = "reloaded terminal handler settlement"
    try await wait { attachEnd.state == .complete }
    precondition(attachEnd.settlements == 1 && client.state == attachState)

    // A spent original cannot rearm on duplicate .left. A confirmed live new
    // incoming generation may reuse that SAME object and UUID for new cleanup.
    manager.delegate?.conversationManager(manager, conversationChanged: attachOriginal)
    waitStage = "duplicate terminal public cleanup"
    try await wait { snapshot(attachID) == nil }
    let duplicateEnd = systemEnd(attachID)
    precondition(duplicateEnd.state == .failed && duplicateEnd.settlements == 1 &&
      endCalls.filter { $0 == attachID }.count == 2,
      "A duplicate terminal delegate cannot rearm the consumed cleanup input")
    let previousGeneration = client.incomingIntake.projection(attachID)!.generation
    client.incomingIntake.reset()
    precondition(client.incomingIntake.projection(attachID)!.generation != previousGeneration &&
      !client.incomingIntake.projection(attachID)!.isLive)
    attachOriginal.state = .idle
    manager.conversations.append(attachOriginal)
    client.incomingIntakeDidChange()
    attachOriginal.state = .left
    manager.conversations.removeAll { $0 === attachOriginal }
    manager.delegate?.conversationManager(manager, conversationChanged: attachOriginal)
    waitStage = "invalidated generation cannot rearm via residual live object"
    try await wait { snapshot(attachID) == nil }
    let invalidatedGenerationEnd = systemEnd(attachID)
    precondition(invalidatedGenerationEnd.state == .failed && invalidatedGenerationEnd.settlements == 1 &&
      endCalls.filter { $0 == attachID }.count == 2 && !client.incomingIntake.projection(attachID)!.isLive,
      "A reset tombstone plus a residual nonleft object is not confirmed new incoming ownership")
    // Drive the actual intake's successful report seam before observing the
    // same original native object live in this new incoming generation.
    let newInvitation = try client.incomingIntake.reserve(payload("terminal-handler-reload"), source: .pushKit)
    guard case .report(let newAttempt) = newInvitation.disposition else { preconditionFailure() }
    precondition(newInvitation.id == attachID)
    client.incomingIntake.complete(newAttempt, outcome: .reported)
    precondition(client.incomingIntake.projection(attachID)!.isLive)
    attachOriginal.state = .idle
    manager.conversations.append(attachOriginal)
    client.incomingIntakeDidChange()
    attachOriginal.state = .left
    manager.conversations.removeAll { $0 === attachOriginal }
    manager.delegate?.conversationManager(manager, conversationChanged: attachOriginal)
    waitStage = "new generation same native terminal cleanup"
    try await wait { snapshot(attachID) == nil }
    let newGenerationEnd = systemEnd(attachID)
    try await wait { newGenerationEnd.state == .complete }
    precondition(newGenerationEnd.settlements == 1 && endCalls.filter { $0 == attachID }.count == 3 &&
      client.incomingIntake.projection(attachID)?.terminal?.ended.reason == .failed,
      "A new live incoming generation can rearm the same native object; cleanup cannot relabel its prior terminal reason")

    // Replacement while late cleanup is held cancels only that old action and
    // cannot stamp local termination onto the replacement or request its End.
    let (heldCleanupID, heldCleanupOriginal) = try await departedOriginal("held-terminal-replacement")
    defer { withExtendedLifetime(heldCleanupOriginal) {} }
    hold.insert(heldCleanupID)
    let heldCleanupEnd = systemEnd(heldCleanupID)
    waitStage = "held late cleanup before replacement"
    try await wait { self.held[heldCleanupID] != nil }
    let heldCleanupAttempts = manager.performAttempts
    let liveReplacement = Conversation(heldCleanupID, state: .idle)
    manager.conversations.append(liveReplacement)
    client.incomingIntakeDidChange()
    precondition(heldCleanupEnd.state == .failed && heldCleanupEnd.settlements == 1 &&
      snapshot(heldCleanupID)?.status == .ringing && snapshot(heldCleanupID)?.ended == nil)
    hold.remove(heldCleanupID); held.removeValue(forKey: heldCleanupID)?.resume()
    for _ in 0..<3 { await Task.yield() }
    precondition(manager.performAttempts == heldCleanupAttempts && heldCleanupEnd.settlements == 1 &&
      liveReplacement.state == .idle && snapshot(heldCleanupID)?.ended == nil,
      "Late completion for a retired native object cannot terminate its replacement")

    // Reset discards retained input, not future first observations. A native
    // object first becoming terminal after reset can supply a new cleanup End.
    let freshResetPayload = payload("first-terminal-after-reset")
    let freshResetID = try await client.reportIncomingConversation(freshResetPayload)
    let freshResetOriginal = manager.conversations.first { $0.uuid == freshResetID }!
    defer { withExtendedLifetime(freshResetOriginal) {} }
    let preResetGeneration = client.incomingIntake.projection(freshResetID)!.generation
    manager.delegate?.conversationManagerDidReset(manager)
    precondition(client.incomingIntake.projection(freshResetID)!.generation != preResetGeneration &&
      !client.incomingIntake.projection(freshResetID)!.isLive)
    freshResetOriginal.state = .left
    manager.conversations.removeAll { $0 === freshResetOriginal }
    manager.delegate?.conversationManager(manager, conversationChanged: freshResetOriginal)
    waitStage = "first terminal observation after reset"
    try await wait { snapshot(freshResetID) == nil }
    let freshResetState = client.state
    let freshResetEnd = systemEnd(freshResetID)
    waitStage = "new genuine cleanup End after reset"
    try await wait { freshResetEnd.state == .complete || freshResetEnd.state == .failed }
    precondition(freshResetEnd.state == .complete && freshResetEnd.settlements == 1 &&
      endCalls.filter { $0 == freshResetID }.count == 1 &&
      endSnapshots[freshResetEnd.uuid]?.status == .ended &&
      endSnapshots[freshResetEnd.uuid]?.payload == freshResetPayload && client.state == freshResetState,
      "Fresh platform input after reset may deliver cleanup once without restoring public state")

    let (resetCleanupID, resetCleanupOriginal) = try await departedOriginal("terminal-reset")
    defer { withExtendedLifetime(resetCleanupOriginal) {} }
    manager.delegate?.conversationManagerDidReset(manager)
    manager.delegate?.conversationManager(manager, conversationChanged: resetCleanupOriginal)
    waitStage = "old native terminal callback after reset"
    try await wait { snapshot(resetCleanupID) == nil }
    let resetCleanupEnd = systemEnd(resetCleanupID)
    precondition(resetCleanupEnd.state == .failed && resetCleanupEnd.settlements == 1 &&
      endCalls.allSatisfy { $0 != resetCleanupID },
      "Reset invalidates old cleanup input; a duplicate old .left cannot rearm it")

    // With two retained native objects for a UUID, an old spent key cannot
    // shadow the newer terminal input or invalidate it via another stale .left.
    let (chainID, chainOld) = try await departedOriginal("terminal-object-chain")
    defer { withExtendedLifetime(chainOld) {} }
    let chainNew = Conversation(chainID, state: .idle)
    manager.conversations.append(chainNew)
    client.incomingIntakeDidChange()
    chainNew.state = .left
    manager.conversations.removeAll { $0 === chainNew }
    manager.delegate?.conversationManager(manager, conversationChanged: chainNew)
    manager.delegate?.conversationManager(manager, conversationChanged: chainOld)
    waitStage = "new native terminal input after stale old callback"
    try await wait { snapshot(chainID) == nil }
    let chainEnd = systemEnd(chainID)
    try await wait { chainEnd.state == .complete }
    precondition(chainEnd.settlements == 1 && endCalls.filter { $0 == chainID }.count == 1)
    withExtendedLifetime(chainNew) {}

    // The genuine End may arrive before the queued public projection removal.
    let earlyID = try await client.reportIncomingConversation(payload("early-terminal-cleanup"))
    let earlyOriginal = manager.conversations.first { $0.uuid == earlyID }!
    defer { withExtendedLifetime(earlyOriginal) {} }
    earlyOriginal.state = .left
    manager.conversations.removeAll { $0 === earlyOriginal }
    manager.delegate?.conversationManager(manager, conversationChanged: earlyOriginal)
    hold.insert(earlyID)
    let earlyEnd = systemEnd(earlyID)
    waitStage = "early cleanup survives queued public state removal"
    try await wait { self.held[earlyID] != nil && snapshot(earlyID) == nil }
    precondition(earlyEnd.state == .running && earlyEnd.settlements == 0,
      "Public projection cleanup cannot cancel an already-delivered genuine cleanup End")
    hold.remove(earlyID); held.removeValue(forKey: earlyID)?.resume()
    try await wait { earlyEnd.state == .complete }
    precondition(earlyEnd.settlements == 1)

    let deathID = try await client.reportIncomingConversation(payload("terminal-native-death"))
    var deathOriginal = manager.conversations.first { $0.uuid == deathID }
    weak let weakDeathOriginal = deathOriginal
    deathOriginal!.state = .left
    manager.conversations.removeAll { $0.uuid == deathID }
    manager.delegate?.conversationManager(manager, conversationChanged: deathOriginal!)
    waitStage = "terminal native death public cleanup"
    try await wait { snapshot(deathID) == nil }
    client.setConversationHandler(nil)
    let deathEnd = systemEnd(deathID)
    deathOriginal = nil
    waitStage = "weak terminal input must not retain original native object"
    try await wait { weakDeathOriginal == nil }
    client.setConversationHandler(handler)
    waitStage = "terminal cleanup after native death while handler detached"
    try await wait { deathEnd.state == .complete || deathEnd.state == .failed }
    precondition(deathEnd.state == .complete && deathEnd.settlements == 1 &&
      endCalls.filter { $0 == deathID }.count == 1 && snapshot(deathID) == nil,
      "Native release cannot discard a genuine cleanup End waiting for its handler")

    // The snapshot value outlives its native object for both incoming and
    // outgoing calls, before End, while detached and during handler work.
    enum NativeReleaseStage: String, CaseIterable { case beforeEnd, detached, running }
    for outgoing in [false, true] {
      for stage in NativeReleaseStage.allCases {
        let value = "native-release-\(outgoing)-\(stage.rawValue)"
        let releasePayload = payload(value)
        let releaseID: UUID
        if outgoing {
          releaseID = try await client.startConversation(to: .init(id: value))
          let startAction = manager.appActions.last!
          waitStage = "outgoing start before terminal native release"
          try await wait { startAction.state == .complete }
        } else { releaseID = try await client.reportIncomingConversation(releasePayload) }
        var original = manager.conversations.first { $0.uuid == releaseID }
        weak let weakOriginal = original
        original!.state = .left
        manager.conversations.removeAll { $0.uuid == releaseID }
        manager.delegate?.conversationManager(manager, conversationChanged: original!)
        waitStage = value + " public cleanup"
        try await wait { snapshot(releaseID) == nil }
        let releaseState = client.state
        let releaseAttempts = manager.performAttempts, releaseReports = manager.reports.count
        let releaseEnd = EndConversationAction(conversationUUID: releaseID)
        systemEndActions.insert(releaseEnd.uuid)
        if stage == .detached { client.setConversationHandler(nil) }
        if stage == .running {
          hold.insert(releaseID)
        }
        if stage != .beforeEnd {
          manager.deliver(releaseEnd)
          if stage == .running {
            waitStage = value + " handler started"
            try await wait { self.held[releaseID] != nil }
          }
        }
        original = nil
        waitStage = value + " native release"
        try await wait { weakOriginal == nil }
        // Long calls can lose their inactive intake tombstone before cleanup.
        // That absence is not new-generation or native replacement evidence.
        let afterRetention = Date().addingTimeInterval(IncomingInvitationGate.metadataRetention + 1)
        client.incomingIntake.removeConversation(releaseID, now: afterRetention)
        precondition(client.incomingIntake.projection(releaseID) == nil)
        if stage != .beforeEnd { client.pruneTerminalCleanup(now: afterRetention) }
        if stage == .running {
          hold.remove(releaseID); held.removeValue(forKey: releaseID)?.resume()
        } else if stage == .detached { client.setConversationHandler(handler) }
        else { manager.deliver(releaseEnd) }
        waitStage = value + " cleanup settlement"
        try await wait { releaseEnd.state == .complete || releaseEnd.state == .failed }
        precondition(releaseEnd.state == .complete && releaseEnd.settlements == 1 &&
          endCalls.filter { $0 == releaseID }.count == 1 &&
          endSnapshots[releaseEnd.uuid]?.status == .ended &&
          endSnapshots[releaseEnd.uuid]?.direction == (outgoing ? .outgoing : .incoming) &&
          endSnapshots[releaseEnd.uuid]?.payload == (outgoing ? nil : releasePayload) &&
          client.state == releaseState && manager.performAttempts == releaseAttempts &&
          manager.reports.count == releaseReports,
          "Native release cannot drop cleanup, change its original input, or recreate public state")
      }
    }

    // Unclaimed values have the shared bounded metadata lifetime. Duplicate
    // terminal delegates cannot extend it while the weak native marker survives.
    let (expiredID, expiredOriginal) = try await departedOriginal("terminal-input-retention")
    defer { withExtendedLifetime(expiredOriginal) {} }
    client.pruneTerminalCleanup(now: Date().addingTimeInterval(IncomingInvitationGate.metadataRetention + 1))
    manager.delegate?.conversationManager(manager, conversationChanged: expiredOriginal)
    waitStage = "expired terminal duplicate public cleanup"
    try await wait { snapshot(expiredID) == nil }
    let expiredEnd = systemEnd(expiredID)
    precondition(expiredEnd.state == .failed && expiredEnd.settlements == 1 &&
      endCalls.allSatisfy { $0 != expiredID }, "Expired terminal metadata cannot be rearmed by duplicate callbacks")

    // With no native key remaining, a live replacement must still cancel the
    // retained cleanup and its late continuation must never target that object.
    for running in [false, true] {
      let value = "dead-terminal-replacement-\(running)"
      let id = try await client.reportIncomingConversation(payload(value))
      var original = manager.conversations.first { $0.uuid == id }
      weak let weakOriginal = original
      original!.state = .left
      manager.conversations.removeAll { $0.uuid == id }
      manager.delegate?.conversationManager(manager, conversationChanged: original!)
      waitStage = value + " public cleanup"
      try await wait { snapshot(id) == nil }
      if running { hold.insert(id) } else { client.setConversationHandler(nil) }
      let action = systemEnd(id)
      if running {
        waitStage = value + " handler started"
        try await wait { self.held[id] != nil }
      }
      original = nil
      waitStage = value + " native release"
      try await wait { weakOriginal == nil }
      let replacement = Conversation(id, state: .idle)
      manager.conversations.append(replacement)
      client.incomingIntakeDidChange()
      precondition(action.state == .failed && action.settlements == 1 &&
        snapshot(id)?.status == .ringing && snapshot(id)?.ended == nil)
      if running { hold.remove(id); held.removeValue(forKey: id)?.resume() }
      else { client.setConversationHandler(handler) }
      for _ in 0..<3 { await Task.yield() }
      precondition(action.settlements == 1 && replacement.state == .idle && snapshot(id)?.ended == nil &&
        endCalls.filter { $0 == id }.count == (running ? 1 : 0),
        "Dead original cleanup cannot invoke or end a live replacement")
    }

    // The actual action cutoff bounds claimed values even after native death.
    for running in [false, true] {
      let value = "dead-terminal-expiry-\(running)"
      let id = try await client.reportIncomingConversation(payload(value))
      var original = manager.conversations.first { $0.uuid == id }
      weak let weakOriginal = original
      original!.state = .left
      manager.conversations.removeAll { $0.uuid == id }
      manager.delegate?.conversationManager(manager, conversationChanged: original!)
      waitStage = value + " public cleanup"
      try await wait { snapshot(id) == nil }
      if running { hold.insert(id) } else { client.setConversationHandler(nil) }
      let action = EndConversationAction(conversationUUID: id)
      action.timeoutDate = Date().addingTimeInterval(2)
      systemEndActions.insert(action.uuid)
      manager.deliver(action)
      if running {
        waitStage = value + " handler started"
        try await wait { self.held[id] != nil }
      }
      original = nil
      waitStage = value + " native release"
      try await wait { weakOriginal == nil }
      waitStage = value + " action cutoff"
      try await wait { action.state == .failed }
      if running { hold.remove(id); held.removeValue(forKey: id)?.resume() }
      else { client.setConversationHandler(handler) }
      for _ in 0..<3 { await Task.yield() }
      let duplicate = systemEnd(id)
      precondition(action.settlements == 1 && duplicate.state == .failed && duplicate.settlements == 1 &&
        endCalls.filter { $0 == id }.count == (running ? 1 : 0),
        "Expired cleanup cannot invoke a late handler or settle twice after native release")
    }

    let (timeoutID, timeoutOriginal) = try await departedOriginal("terminal-native-timeout")
    defer { withExtendedLifetime(timeoutOriginal) {} }
    hold.insert(timeoutID)
    let timeoutEnd = systemEnd(timeoutID)
    waitStage = "terminal native timeout held handler"
    try await wait { self.held[timeoutID] != nil }
    timeoutEnd.fail()
    manager.delegate?.conversationManager(manager, timedOutPerforming: timeoutEnd)
    hold.remove(timeoutID); held.removeValue(forKey: timeoutID)?.resume()
    for _ in 0..<3 { await Task.yield() }
    let afterTimeoutEnd = systemEnd(timeoutID)
    precondition(timeoutEnd.settlements == 1 && afterTimeoutEnd.state == .failed &&
      afterTimeoutEnd.settlements == 1 && endCalls.filter { $0 == timeoutID }.count == 1,
      "A native timeout consumes cleanup input and late handler completion cannot settle again")
    // Metadata-only updates must preserve the exact original calling address.
    for caller in [
      try Caller(handleType: .phone, value: "+1 (202) 555-0123", displayName: "Phone", hostContactID: "contact-phone"),
      try Caller(handleType: .email, value: "caller@example.com", displayName: "Email", hostContactID: "contact-email"),
      try Caller(handleType: .generic, value: "remote-user", displayName: "Generic", hostContactID: "contact-generic")
    ] {
      let id = try await client.reportIncomingConversation(.init(eventId: UUID().uuidString,
        serverCallId: UUID().uuidString, caller: caller))
      try await client.reportConversation(id, report: .updated(members: nil, video: true))
      guard case .conversationUpdated(let update) = manager.reports.last?.1 else { preconditionFailure() }
      let type: Handle.Kind = caller.handleType == .phone ? .phoneNumber : caller.handleType == .email ? .emailAddress : .generic
      precondition(update.members == [Handle(type: type, value: caller.value, displayName: caller.displayName)],
        "A video-only update must not replace the calling address with an opaque contact ID")
      precondition(snapshot(id)?.payload?.caller.hostContactID == caller.hostContactID,
        "The host contact ID stays in the Caller payload")
      let replacement = Participant(id: "explicit-replacement", displayName: "Replacement")
      try await client.reportConversation(id, report: .updated(members: [replacement], video: nil))
      try await client.reportConversation(id, report: .updated(members: nil, video: false))
      guard case .conversationUpdated(let replaced) = manager.reports.last?.1 else { preconditionFailure() }
      precondition(replaced.members == [Handle(type: .generic, value: replacement.id, displayName: replacement.displayName)],
        "Explicit member changes remain authoritative on later metadata-only updates")
    }
    // A real reset changes intake generations but does not invent a new server
    // ownership notification. Residual native objects still need an end report.
    client.conversationManagerDidReset(manager)
    manager.conversations.removeAll { $0.uuid == racingID }
    let resetResidual = Conversation(racingID, state: .idle)
    manager.conversations.append(resetResidual)
    client.incomingIntakeDidChange()
    precondition(resetResidual.state == .left && elsewhereEvents.filter { $0.conversationID == racingID }.count == 1,
      "Reset-retained ownership cleanup cannot emit the same server event twice")
    client.removeEventObserver(elsewhereObserver)
    precondition(held.isEmpty)
    print("{\"success\":true,\"groups\":56,\"actualClientAndCoordinatorAndIntake\":true,\"nativeFrameworkMeasured\":false}")
  }
}

@main struct ReportContractTests {
  @MainActor static func main() async throws { try await ReportControls().run() }
}
