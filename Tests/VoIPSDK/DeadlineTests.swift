import Foundation

@main
struct DeadlineTests {
  @MainActor static func main() async {
    let coordinator = ConversationActionCoordinator(policy: .fail)
    let conversation = UUID()
    let platformDeadline = Date().addingTimeInterval(30)
    let action = PendingAction(id: UUID(), kind: .join, deadline: platformDeadline, origin: .system)
    coordinator.enqueue(conversationID: conversation, action: action,
      isPending: { true }, settle: { _ in })
    precondition(coordinator.pending(for: conversation)?.deadline == platformDeadline.addingTimeInterval(-1.5),
      "Pending actions expose the effective deadline 1.5 seconds before the platform timeout")
    coordinator.cancelAll(reason: .reset)

    // The default production clock and scheduler run here. No injected clock or
    // manual timer firing can qualify the deadline safety checks below.
    for policy in [UnhandledActionPolicy.accept, .fail] {
      let owner = ConversationActionCoordinator(policy: policy)
      let timeout = Date().addingTimeInterval(2)
      var result: [(Bool, Date)] = []
      owner.enqueue(conversationID: conversation,
        action: PendingAction(id: UUID(), kind: .join, deadline: timeout, origin: .system),
        isPending: { true }, settle: { result.append(($0, Date())) })
      precondition(result.isEmpty, "Policy cannot fire before its effective deadline")
      await wait { !result.isEmpty }
      precondition(result.count == 1 && result[0].0 == (policy == .accept))
      precondition(result[0].1 >= timeout.addingTimeInterval(-1.5) &&
        result[0].1 < timeout.addingTimeInterval(-1),
        "Real scheduler must settle with at least one second left before platform timeout")
      var lateCalls = 0
      owner.setHandler(ConversationHandler(join: { _, _ in lateCalls += 1 }, start: { _, _ in }, end: { _, _ in }))
      await turns()
      precondition(lateCalls == 0 && result.count == 1, "A late handler cannot recover an expired action")
    }

    let running = ConversationActionCoordinator(policy: .accept)
    running.snapshot = { _ in snapshot(conversation) }
    let runningTimeout = Date().addingTimeInterval(2)
    var runningSignal: ConversationCancellationSignal?
    var continuation: CheckedContinuation<Void, Never>?
    var runningResult: [(Bool, Date)] = []
    running.setHandler(ConversationHandler(join: { _, context in
      precondition(context.deadline == runningTimeout.addingTimeInterval(-1.5),
        "Handler and pending snapshot share the effective deadline without subtracting twice")
      runningSignal = context.signal
      await withCheckedContinuation { continuation = $0 }
    }, start: { _, _ in }, end: { _, _ in }))
    running.enqueue(conversationID: conversation,
      action: PendingAction(id: UUID(), kind: .join, deadline: runningTimeout, origin: .app),
      isPending: { true }, settle: { runningResult.append(($0, Date())) })
    await wait { continuation != nil }
    await wait { !runningResult.isEmpty }
    precondition(runningSignal?.reason == .deadline && runningResult.count == 1 &&
      runningResult[0].0 == false && runningResult[0].1 < runningTimeout.addingTimeInterval(-1),
      "A running handler fails and is cancelled before the platform deadline even under accept policy")
    continuation?.resume()
    await turns()
    precondition(runningResult.count == 1, "Late successful work cannot settle twice")

    let cancelled = ConversationActionCoordinator(policy: .accept)
    cancelled.snapshot = { _ in snapshot(conversation) }
    var cancelledSignal: ConversationCancellationSignal?
    var cancelledWork: CheckedContinuation<Void, Never>?
    var cancelledResults: [Bool] = []
    cancelled.setHandler(ConversationHandler(join: { _, context in
      cancelledSignal = context.signal
      await withCheckedContinuation { cancelledWork = $0 }
    }, start: { _, _ in }, end: { _, _ in }))
    let cancelledAction = PendingAction(id: UUID(), kind: .join, deadline: Date().addingTimeInterval(2), origin: .system)
    cancelled.enqueue(conversationID: conversation, action: cancelledAction,
      isPending: { true }, settle: { cancelledResults.append($0) })
    await wait { cancelledWork != nil }
    cancelled.cancel(cancelledAction.id, reason: .platformTimeout)
    cancelledWork?.resume()
    try? await Task.sleep(for: .milliseconds(650))
    precondition(cancelledSignal?.reason == .platformTimeout && cancelledResults.isEmpty,
      "Platform cancellation suppresses the handler result and scheduled accept policy")

    for remaining in [-1.0, 0.5] {
      let owner = ConversationActionCoordinator(policy: .accept)
      var results: [Bool] = []
      let timeout = Date().addingTimeInterval(remaining)
      owner.enqueue(conversationID: conversation,
        action: PendingAction(id: UUID(), kind: .join, deadline: timeout, origin: .system),
        isPending: { true }, settle: { results.append($0) })
      precondition(results == [remaining > 0],
        "Arrival inside the safety margin settles immediately; past platform expiry never accepts")
    }

    let delayed = ConversationActionCoordinator(policy: .accept)
    var delayedResults: [Bool] = []
    delayed.enqueue(conversationID: conversation,
      action: PendingAction(id: UUID(), kind: .join, deadline: Date().addingTimeInterval(1.6), origin: .system),
      isPending: { true }, settle: { delayedResults.append($0) })
    blockActorForControl()
    await wait { !delayedResults.isEmpty }
    precondition(delayedResults == [false],
      "A blocked actor cannot be preempted, but resuming after platform expiry must never accept")
    print("Deadline controls passed: seven real-clock boundary, policy, context, late-handler, cancellation and blocked-actor groups")
  }

  @MainActor private static func wait(until predicate: @MainActor () -> Bool) async {
    let clock = ContinuousClock(), limit = ContinuousClock.now.advanced(by: .seconds(3))
    while !predicate() {
      precondition(clock.now < limit, "Real-clock deadline control exceeded its bounded wait")
      try? await Task.sleep(for: .milliseconds(10))
    }
  }
  @MainActor private static func turns() async { for _ in 0..<8 { await Task.yield() } }
  @MainActor private static func blockActorForControl() { Thread.sleep(forTimeInterval: 1.7) }
  private static func snapshot(_ id: UUID) -> ConversationSnapshot {
    ConversationSnapshot(id: id, direction: .incoming, status: .ringing, members: [],
      capabilities: .init(), isMuted: false, isVideo: false)
  }
}
