import Foundation

@main
struct DeadlineTests {
  @MainActor static func main() async {
    await boundedDeadlineControls()
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
    print("Deadline controls passed: conservative action bounds, original delivery/reload deadlines, and seven real-clock boundary/policy/cancellation groups")
  }

  @MainActor private static func boundedDeadlineControls() async {
    let delivered = Date(timeIntervalSince1970: 100)
    let id = UUID()
    for (kind, advertised, expected) in [
      (ConversationActionKind.join, 200.0, 161.0), (.join, 130, 127), (.join, 104, 101),
      (.start, 700, 697), (.hold, 130, 103.8), (.end, 130, 103.8),
      (.mute, 130, 128.5), (.tones, 130, 128.5),
    ] {
      let owner = ConversationActionCoordinator(policy: .fail, now: { delivered }, schedule: { _, _ in {} })
      owner.prepareForFulfillment = { _, _ in }
      owner.enqueue(conversationID: id,
        action: .init(id: UUID(), kind: kind, deadline: Date(timeIntervalSince1970: advertised), origin: .system),
        isPending: { true }, settle: { _ in })
      precondition(owner.pending(for: id)?.deadline == Date(timeIntervalSince1970: expected),
        "Only start/join reserves three seconds for final audio work; other margins and earlier expiry stay intact")
      owner.cancelAll(reason: .reset)
    }
    // Literal outcomes bind the policy to measured bounds independently of its selector.
    for (kind, advertised, expected) in [
      (ConversationActionKind.hold, 130.0, 103.8), (.end, 130, 103.8),
      (.join, 200, 162.5), (.join, 130, 128.5),
      (.hold, 102, 100.5), (.end, 102, 100.5), (.join, 102, 100.5),
      (.start, 700, 698.5), (.mute, 130, 128.5), (.tones, 130, 128.5),
    ] {
      let coordinator = ConversationActionCoordinator(policy: .fail, now: { delivered }, schedule: { _, _ in {} })
      let action = PendingAction(id: UUID(), kind: kind, deadline: Date(timeIntervalSince1970: advertised), origin: .system)
      coordinator.enqueue(conversationID: id, action: action, isPending: { true }, settle: { _ in })
      precondition(coordinator.pending(for: id)?.deadline == Date(timeIntervalSince1970: expected),
        "Measured bounds shorten Pause/End/Join work without extending an earlier advertised timeout or changing other kinds")
      precondition(action.deadline == Date(timeIntervalSince1970: advertised), "The input advertised date remains unchanged")
    }
    for policy in [UnhandledActionPolicy.accept, .fail] {
      let clock = DeadlineClock(delivered)
      let coordinator = ConversationActionCoordinator(policy: policy, now: { clock.now }, schedule: clock.schedule)
      var results: [Bool] = []
      let action = PendingAction(id: UUID(), kind: .end, deadline: Date(timeIntervalSince1970: 130), origin: .system)
      coordinator.enqueue(conversationID: id, action: action, isPending: { true }, settle: { results.append($0) })
      clock.advance(Date(timeIntervalSince1970: 103.7))
      coordinator.setHandler(nil)
      coordinator.enqueue(conversationID: id, action: action, isPending: { true }, settle: { _ in
        preconditionFailure("Duplicate delivery cannot replace the original action")
      })
      precondition(results.isEmpty && coordinator.pending(for: id)?.deadline == Date(timeIntervalSince1970: 103.8),
        "Reload and duplicate delivery preserve the original effective deadline")
      clock.advance(Date(timeIntervalSince1970: 103.8))
      precondition(results == [policy == .accept] && coordinator.pending(for: id) == nil,
        "No-handler policy applies once at the bounded deadline")
      clock.advance(Date(timeIntervalSince1970: 130))
      precondition(results.count == 1)
    }
    for (now, expected) in [(104.0, true), (106.0, false)] {
      let coordinator = ConversationActionCoordinator(policy: .accept,
        now: { Date(timeIntervalSince1970: now) }, schedule: { _, _ in {} })
      var results: [Bool] = []
      coordinator.enqueue(conversationID: id,
        action: .init(id: UUID(), kind: .end, deadline: Date(timeIntervalSince1970: 130), origin: .system),
        deliveredAt: delivered, isPending: { true }, settle: { results.append($0) })
      precondition(results == [expected],
        "Delayed enqueue uses callback delivery time; expiry cannot be extended by intervening work")
    }
    let clock = DeadlineClock(delivered)
    let coordinator = ConversationActionCoordinator(policy: .accept, now: { clock.now }, schedule: clock.schedule)
    coordinator.snapshot = { _ in snapshot(id) }
    var first: CheckedContinuation<Void, Never>?
    var replacement: CheckedContinuation<Void, Never>?
    var firstSignal: ConversationCancellationSignal?
    var replacementSignal: ConversationCancellationSignal?
    var results: [Bool] = []
    coordinator.setHandler(.init(join: { _, _ in }, start: { _, _ in }, end: { _, context in
      firstSignal = context.signal
      await withCheckedContinuation { first = $0 }
    }))
    coordinator.enqueue(conversationID: id,
      action: .init(id: UUID(), kind: .end, deadline: Date(timeIntervalSince1970: 130), origin: .system),
      isPending: { true }, settle: { results.append($0) })
    await wait { first != nil }
    clock.advance(Date(timeIntervalSince1970: 101))
    coordinator.setHandler(nil)
    first?.resume()
    await turns()
    precondition(firstSignal?.reason == .replaced && results.isEmpty)
    clock.advance(Date(timeIntervalSince1970: 102))
    coordinator.setHandler(.init(join: { _, _ in }, start: { _, _ in }, end: { _, context in
      precondition(context.deadline == Date(timeIntervalSince1970: 103.8),
        "A redelivered handler sees the original bound, with the margin subtracted once")
      replacementSignal = context.signal
      await withCheckedContinuation { replacement = $0 }
    }))
    await wait { replacement != nil }
    clock.advance(Date(timeIntervalSince1970: 103.8))
    precondition(replacementSignal?.reason == .deadline && results == [false])
    replacement?.resume()
    await turns()
    precondition(results == [false], "Late handlers cannot revive a bounded action")
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

@MainActor private final class DeadlineClock {
  var now: Date
  private var jobs: [UUID: (Date, @MainActor () -> Void)] = [:]
  init(_ now: Date) { self.now = now }
  func schedule(_ deadline: Date, _ fire: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
    let id = UUID(); jobs[id] = (deadline, fire)
    return { self.jobs.removeValue(forKey: id) }
  }
  func advance(_ date: Date) {
    now = date
    for (id, job) in jobs.filter({ $0.value.0 <= date }) { jobs.removeValue(forKey: id); job.1() }
  }
}
