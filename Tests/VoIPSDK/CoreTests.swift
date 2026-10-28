import Foundation

@main
struct CoreTests {
  @MainActor static func main() async throws {
    let now = Date(timeIntervalSince1970: 100)
    var gate = IncomingInvitationGate()
    let first = gate.register(eventId: "event-a", serverCallId: "server-a", now: now)
    let simultaneous = gate.register(eventId: "event-b", serverCallId: "server-a", now: now)
    precondition(first.isNew && !simultaneous.isNew && first.id == simultaneous.id,
                 "In-flight cross-source registration must ring once")
    gate.removeConversation(first.id, now: now)
    let replay = gate.register(eventId: "event-a", serverCallId: "server-c", now: now.addingTimeInterval(120))
    precondition(!replay.isNew && replay.id == first.id, "Event replay is inclusive through two minutes")
    let expired = gate.register(eventId: "event-a", serverCallId: "server-c", now: now.addingTimeInterval(120.001))
    precondition(expired.isNew && expired.id != first.id, "Expired events can ring again")
    let failed = gate.register(eventId: "report-failed", serverCallId: "server-failed", now: now)
    gate.discardUnreported(failed.id)
    let retried = gate.register(eventId: "report-failed", serverCallId: "server-failed", now: now)
    precondition(retried.isNew && retried.id != failed.id, "Failed platform reports cannot poison retry deduplication")
    let endedServer = gate.register(eventId: "server-end-1", serverCallId: "ended-server", now: now)
    gate.removeConversation(endedServer.id, now: now.addingTimeInterval(5))
    let lateServerDuplicate = gate.register(eventId: "server-end-2", serverCallId: "ended-server", now: now.addingTimeInterval(120))
    precondition(!lateServerDuplicate.isNew && lateServerDuplicate.id == endedServer.id)
    let expiredServer = gate.register(eventId: "server-end-3", serverCallId: "ended-server", now: now.addingTimeInterval(120.001))
    precondition(expiredServer.isNew, "Server tombstone uses first registration and is not refreshed by duplicates")
    let longActive = gate.register(eventId: "active-1", serverCallId: "long-active", now: now)
    let stillActive = gate.register(eventId: "active-2", serverCallId: "long-active", now: now.addingTimeInterval(300))
    precondition(!stillActive.isNew && stillActive.id == longActive.id, "Active server binding outlives two minutes")
    gate.removeConversation(longActive.id, now: now.addingTimeInterval(300))
    let afterActive = gate.register(eventId: "active-3", serverCallId: "long-active", now: now.addingTimeInterval(300))
    precondition(afterActive.isNew)
    let revived = gate.register(eventId: "revived-1", serverCallId: "revived-server", now: now)
    gate.removeConversation(revived.id, now: now.addingTimeInterval(10))
    gate.markActive(revived.id, serverCallId: "revived-server", now: now.addingTimeInterval(20))
    let revivedDuplicate = gate.register(eventId: "revived-2", serverCallId: "revived-server", now: now.addingTimeInterval(300))
    precondition(!revivedDuplicate.isNew && revivedDuplicate.id == revived.id,
      "A successful same-UUID re-report reactivates the server binding")
    let clock = TestClock(now: now)
    let coordinator = ConversationActionCoordinator(policy: .fail, now: { clock.now }, schedule: clock.schedule)
    let conversationID = UUID()
    var settlements: [Bool] = []
    let pending = PendingAction(id: UUID(), kind: .join, deadline: now.addingTimeInterval(30), origin: .system)
    coordinator.enqueue(conversationID: conversationID, action: pending, isPending: { true }, settle: { settlements.append($0) })
    precondition(coordinator.pending(for: conversationID)?.id == pending.id && settlements.isEmpty,
                 "Cold-launch action stays pending without a handler")
    clock.advance(to: now.addingTimeInterval(30))
    precondition(settlements == [false] && coordinator.pending(for: conversationID) == nil,
                 "Actual deadline fails and removes an unhandled action")
    // A late handler can accept a retained action exactly once.
    let acceptedCoordinator = ConversationActionCoordinator(policy: .accept, now: { clock.now }, schedule: clock.schedule)
    acceptedCoordinator.snapshot = { _ in sampleSnapshot(conversationID) }
    var accepted: [Bool] = []
    let lateAction = PendingAction(id: UUID(), kind: .join, deadline: clock.now.addingTimeInterval(10), origin: .app)
    acceptedCoordinator.enqueue(conversationID: conversationID, action: lateAction, isPending: { true }, settle: { accepted.append($0) })
    acceptedCoordinator.setHandler(ConversationHandler(join: { c, context in
      precondition(c.id == conversationID && context.origin == .app)
    }, start: { _, _ in }, end: { _, _ in }))
    for _ in 0..<4 { await Task.yield() }
    precondition(accepted == [true] && acceptedCoordinator.pending(for: conversationID) == nil)
    clock.advance(to: clock.now.addingTimeInterval(10))
    precondition(accepted == [true], "A fired/cancelled timer cannot settle twice")

    // Replacing a handler aborts the prior signal; its late result cannot settle the action.
    let replacedCoordinator = ConversationActionCoordinator(policy: .fail, now: { clock.now }, schedule: clock.schedule)
    replacedCoordinator.snapshot = { _ in sampleSnapshot(conversationID) }
    var oldContinuation: CheckedContinuation<Void, Never>?
    var oldSignal: ConversationCancellationSignal?
    var replacementResults: [Bool] = []
    replacedCoordinator.setHandler(ConversationHandler(join: { _, context in
      oldSignal = context.signal
      await withCheckedContinuation { oldContinuation = $0 }
    }, start: { _, _ in }, end: { _, _ in }))
    let replacedAction = PendingAction(id: UUID(), kind: .join, deadline: clock.now.addingTimeInterval(15), origin: .system)
    replacedCoordinator.enqueue(conversationID: conversationID, action: replacedAction, isPending: { true }, settle: { replacementResults.append($0) })
    for _ in 0..<4 { await Task.yield() }
    precondition(oldContinuation != nil)
    replacedCoordinator.setHandler(ConversationHandler(join: { _, _ in throw SampleError.failed }, start: { _, _ in }, end: { _, _ in }))
    for _ in 0..<4 { await Task.yield() }
    oldContinuation?.resume()
    for _ in 0..<4 { await Task.yield() }
    precondition(oldSignal?.reason == .replaced && replacementResults == [false])

    let expiredCoordinator = ConversationActionCoordinator(policy: .accept, now: { clock.now }, schedule: clock.schedule)
    let platformPending = TestFlag()
    var expiredResults: [Bool] = []
    let expiredAction = PendingAction(id: UUID(), kind: .end, deadline: clock.now.addingTimeInterval(2), origin: .system)
    expiredCoordinator.enqueue(conversationID: conversationID, action: expiredAction, isPending: { platformPending.value }, settle: { expiredResults.append($0) })
    platformPending.value = false
    clock.advance(to: clock.now.addingTimeInterval(2))
    precondition(expiredResults.isEmpty && expiredCoordinator.pending(for: conversationID) == nil,
      "Accept policy never resurrects a platform-settled action")
    let acceptClock = TestClock(now: now)
    let noHandlerAccept = ConversationActionCoordinator(policy: .accept, now: { acceptClock.now }, schedule: acceptClock.schedule)
    var acceptedWithoutHandler: [Bool] = []
    let noHandlerAction = PendingAction(id: UUID(), kind: .join, deadline: now.addingTimeInterval(7), origin: .system)
    noHandlerAccept.enqueue(conversationID: conversationID, action: noHandlerAction, isPending: { true }, settle: { acceptedWithoutHandler.append($0) })
    acceptClock.advance(to: now.addingTimeInterval(5.49))
    precondition(acceptedWithoutHandler.isEmpty)
    acceptClock.advance(to: now.addingTimeInterval(5.5))
    precondition(acceptedWithoutHandler == [true], "Explicit accept policy applies at the effective deadline")

    let activeClock = TestClock(now: now)
    let active = ConversationActionCoordinator(policy: .accept, now: { activeClock.now }, schedule: activeClock.schedule)
    active.snapshot = { _ in sampleSnapshot(conversationID) }
    var runningContinuation: CheckedContinuation<Void, Never>?
    var runningSignal: ConversationCancellationSignal?
    var runningResults: [Bool] = []
    active.setHandler(ConversationHandler(join: { _, context in
      runningSignal = context.signal
      await withCheckedContinuation { runningContinuation = $0 }
    }, start: { _, _ in }, end: { _, _ in }))
    let runningAction = PendingAction(id: UUID(), kind: .join, deadline: now.addingTimeInterval(3), origin: .system)
    active.enqueue(conversationID: conversationID, action: runningAction, isPending: { true }, settle: { runningResults.append($0) })
    for _ in 0..<4 { await Task.yield() }
    activeClock.advance(to: now.addingTimeInterval(3))
    precondition(runningSignal?.reason == .deadline && runningResults == [false],
      "Accept policy cannot accept an already-delivered hung handler")
    runningContinuation?.resume()
    for _ in 0..<4 { await Task.yield() }
    precondition(runningResults == [false], "Late successful handler results cannot resurrect an expired action")

    let optional = ConversationActionCoordinator(policy: .fail, now: { now }, schedule: acceptClock.schedule)
    optional.snapshot = { _ in sampleSnapshot(conversationID) }
    optional.setHandler(ConversationHandler(join: { _, _ in }, start: { _, _ in }, end: { _, _ in }))
    var optionalResults: [Bool] = []
    for type in [ConversationActionKind.hold, .mute, .tones] {
      optional.enqueue(conversationID: conversationID,
        action: PendingAction(id: UUID(), kind: type, deadline: now.addingTimeInterval(20), origin: .system),
        isPending: { true }, settle: { optionalResults.append($0) })
    }
    precondition(optionalResults == [true, true, true], "Omitted optional handlers accept")

    let reentrant = ConversationActionCoordinator(policy: .fail, now: { now }, schedule: acceptClock.schedule)
    reentrant.snapshot = { _ in sampleSnapshot(conversationID) }
    var reentrantCalls = 0
    let reentrantHandler = ConversationHandler(join: { _, _ in reentrantCalls += 1 }, start: { _, _ in }, end: { _, _ in })
    reentrant.didChange = { reentrant.setHandler(reentrantHandler) }
    reentrant.enqueue(conversationID: conversationID,
      action: PendingAction(id: UUID(), kind: .join, deadline: now.addingTimeInterval(5), origin: .system),
      isPending: { true }, settle: { _ in })
    for _ in 0..<8 { await Task.yield() }
    precondition(reentrantCalls == 1, "Synchronous handler attachment from state notification cannot duplicate transport work")

    let cancelBeforeDispatch = ConversationActionCoordinator(policy: .fail, now: { now }, schedule: acceptClock.schedule)
    cancelBeforeDispatch.snapshot = { _ in sampleSnapshot(conversationID) }
    var cancelledCalls = 0
    cancelBeforeDispatch.setHandler(ConversationHandler(join: { _, _ in cancelledCalls += 1 }, start: { _, _ in }, end: { _, _ in }))
    cancelBeforeDispatch.enqueue(conversationID: conversationID,
      action: PendingAction(id: UUID(), kind: .join, deadline: now.addingTimeInterval(5), origin: .system),
      isPending: { true }, settle: { _ in })
    cancelBeforeDispatch.cancelConversation(conversationID)
    for _ in 0..<8 { await Task.yield() }
    precondition(cancelledCalls == 0, "Cancelled delivery never starts transport work")

    let nestedReplacement = ConversationActionCoordinator(policy: .fail, now: { now }, schedule: acceptClock.schedule)
    nestedReplacement.snapshot = { _ in sampleSnapshot(conversationID) }
    var firstHandlerContinuation: CheckedContinuation<Void, Never>?
    var nestedCalls: [String] = []
    let innermost = ConversationHandler(join: { _, _ in nestedCalls.append("inner") }, start: { _, _ in }, end: { _, _ in })
    nestedReplacement.setHandler(ConversationHandler(join: { _, context in
      context.signal.observe { _ in nestedReplacement.setHandler(innermost) }
      await withCheckedContinuation { firstHandlerContinuation = $0 }
    }, start: { _, _ in }, end: { _, _ in }))
    nestedReplacement.enqueue(conversationID: conversationID,
      action: PendingAction(id: UUID(), kind: .join, deadline: now.addingTimeInterval(5), origin: .system),
      isPending: { true }, settle: { _ in })
    for _ in 0..<8 { await Task.yield() }
    nestedReplacement.setHandler(ConversationHandler(join: { _, _ in nestedCalls.append("outer") }, start: { _, _ in }, end: { _, _ in }))
    for _ in 0..<8 { await Task.yield() }
    firstHandlerContinuation?.resume()
    for _ in 0..<8 { await Task.yield() }
    precondition(nestedCalls == ["inner"], "Cancellation observer replacement supersedes the outer replacement")

    var placeholder = ConversationRecord(direction: .outgoing, members: [], capabilities: .init(), video: false)
    placeholder.metadataIsPlaceholder = true
    placeholder.seenInManager = true
    placeholder.enrichSystemStart(members: [Participant(id: "system-dialed", displayName: "Siri")], video: true)
    precondition(placeholder.members.first?.id == "system-dialed" && placeholder.video && placeholder.seenInManager)
    placeholder.enrichSystemStart(members: [Participant(id: "replacement")], video: false)
    precondition(placeholder.members.first?.id == "system-dialed" && placeholder.video,
      "A repeated system action cannot overwrite registered app metadata")

    let weakClock = TestClock(now: now)
    let weakCoordinator = ConversationActionCoordinator(policy: .fail, now: { weakClock.now }, schedule: weakClock.schedule)
    weakCoordinator.snapshot = { _ in sampleSnapshot(conversationID) }
    var resource: TestResource? = TestResource()
    let releasedResource = WeakTestResource(resource)
    var hungContinuation: CheckedContinuation<Void, Never>?
    weakCoordinator.setHandler(ConversationHandler(join: { _, _ in
      await withCheckedContinuation { hungContinuation = $0 }
    }, start: { _, _ in }, end: { _, _ in }))
    weakCoordinator.enqueue(conversationID: conversationID,
      action: PendingAction(id: UUID(), kind: .join, deadline: now.addingTimeInterval(3), origin: .system),
      isPending: { true }, settle: { [owned = resource!] _ in owned.wasSettled = true })
    resource = nil
    for _ in 0..<8 { await Task.yield() }
    weakClock.advance(to: now.addingTimeInterval(3))
    precondition(releasedResource.value == nil, "Expired platform-action closures are released even if the handler ignores cancellation")
    hungContinuation?.resume()
    for _ in 0..<8 { await Task.yield() }

    let wire = Data(#"{"eventId":"e","serverCallId":"s","caller":{"handleType":"phone","value":"+15555550142","displayName":"caller","hostContactID":"caller"},"hasVideo":true,"startedAt":"2026-10-22T00:00:00.123Z","metadata":{"flag":true,"nested":[1,"two",null]}}"#.utf8)
    let payload = try JSONDecoder().decode(IncomingCallPayload.self, from: wire)
    precondition(payload.eventId == "e" && payload.caller.handleType == .phone && payload.caller.value == "+15555550142" && payload.hasVideo)
    precondition(payload.metadata?["flag"] == .bool(true) && payload.startedAt == "2026-10-22T00:00:00.123Z")
    let roundtrip = try JSONDecoder().decode(IncomingCallPayload.self, from: JSONEncoder().encode(payload))
    precondition(roundtrip == payload)
    print("Core tests passed: dedup/in-flight, two-minute boundary, cold launch, late attachment, replacement, deadline/policy, no resurrection, optional handlers and wire roundtrip")
  }
}

@MainActor
final class TestClock {
  var now: Date
  var jobs: [UUID: (Date, @MainActor () -> Void)] = [:]
  init(now: Date) { self.now = now }
  func schedule(at: Date, fire: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
    let id = UUID(); jobs[id] = (at, fire)
    return { self.jobs.removeValue(forKey: id) }
  }
  func advance(to date: Date) {
    now = date
    for (id, job) in jobs.filter({ $0.value.0 <= date }) {
      jobs.removeValue(forKey: id); job.1()
    }
  }
}

enum SampleError: Error { case failed }
func sampleSnapshot(_ id: UUID) -> ConversationSnapshot {
  ConversationSnapshot(id: id, direction: .incoming, status: .ringing,
    members: [Participant(id: "caller")], capabilities: .init(), isMuted: false, isVideo: false)
}

@MainActor final class TestFlag { var value = true }

@MainActor final class TestResource { var wasSettled = false }

@MainActor final class WeakTestResource { weak var value: TestResource?; init(_ value: TestResource?) { self.value = value } }
