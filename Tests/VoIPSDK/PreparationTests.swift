import Foundation

@main
struct PreparationTests {
  @MainActor static func main() async {
    let start = Date(timeIntervalSince1970: 100)
    let conversationID = UUID()
    func snapshot() -> ConversationSnapshot {
      .init(id: conversationID, direction: .incoming, status: .ringing,
        members: [], capabilities: .init(), isMuted: false, isVideo: false)
    }
    for scenario in ["ready-handler", "ready-policy", "hung-policy", "failure", "cancel", "replacement", "platform-settled"] {
      let clock = PreparationClock(start)
      let coordinator = ConversationActionCoordinator(policy: .accept, now: { clock.now }, schedule: clock.schedule)
      coordinator.snapshot = { _ in snapshot() }
      let preparation = PreparationGate()
      var preparedCalls = 0
      var handlers: [String] = []
      var settlements: [Bool] = []
      let platformPending = PreparationFlag()
      coordinator.prepareAction = { _, action in
        preparedCalls += 1
        precondition(action.deadline == start.addingTimeInterval(8.5))
        try await preparation.run()
      }
      precondition(preparedCalls == 0, "Installing the preparation hook cannot touch audio at launch")
      if scenario != "ready-policy" && scenario != "hung-policy" {
        coordinator.setHandler(.init(join: { _, context in
          precondition(context.deadline == start.addingTimeInterval(8.5))
          handlers.append("first")
        }, start: { _, _ in }, end: { _, _ in }))
      }
      let action = PendingAction(id: UUID(), kind: .join, deadline: start.addingTimeInterval(10), origin: .system)
      coordinator.enqueue(conversationID: conversationID, action: action,
        isPending: { platformPending.value }, settle: { settlements.append($0) })
      await preparation.waitUntilEntered()
      precondition(preparedCalls == 1 && handlers.isEmpty && settlements.isEmpty)
      precondition(coordinator.pending(for: conversationID)?.deadline == start.addingTimeInterval(8.5))
      switch scenario {
      case "hung-policy":
        clock.advance(start.addingTimeInterval(8.5))
        precondition(settlements == [false], "Accept policy cannot accept unfinished mandatory preparation")
      case "cancel": coordinator.cancelAll(reason: .reset)
      case "replacement":
        coordinator.setHandler(.init(join: { _, _ in handlers.append("replacement") }, start: { _, _ in }, end: { _, _ in }))
      case "platform-settled": platformPending.value = false
      default: break
      }
      preparation.finish(failing: scenario == "failure")
      for _ in 0..<12 { await Task.yield() }
      switch scenario {
      case "ready-policy":
        precondition(handlers.isEmpty && settlements.isEmpty)
        clock.advance(start.addingTimeInterval(8.5))
        precondition(settlements == [true], "Prepared no-handler accept keeps the effective deadline")
      case "hung-policy", "cancel", "failure":
        precondition(handlers.isEmpty && settlements == [false])
      case "replacement": precondition(handlers == ["replacement"] && settlements == [true])
      case "platform-settled": precondition(handlers.isEmpty && settlements.isEmpty)
      default: precondition(handlers == ["first"] && settlements == [true])
      }
      precondition(coordinator.pending(for: conversationID) == nil)
    }
    let optional = ConversationActionCoordinator(policy: .accept)
    var preparations = 0
    optional.prepareAction = { _, _ in preparations += 1 }
    optional.snapshot = { _ in snapshot() }
    optional.setHandler(.init(join: { _, _ in }, start: { _, _ in }, end: { _, _ in }))
    var held: [Bool] = []
    optional.enqueue(conversationID: conversationID,
      action: .init(id: UUID(), kind: .hold, deadline: Date().addingTimeInterval(10), origin: .system, held: true),
      isPending: { true }, settle: { held.append($0) })
    precondition(held == [true] && preparations == 0, "Only real start/join actions begin preparation")
    print("Call-time preparation controls passed: eight groups; no launch work, ready/hung accept, failure, cancellation, replacement and platform settlement")
  }
}

@MainActor private final class PreparationGate {
  private var entered = false
  private var waiting: CheckedContinuation<Void, Never>?
  private var result: CheckedContinuation<Void, any Error>?
  func run() async throws {
    try await withCheckedThrowingContinuation { continuation in
      result = continuation; entered = true; waiting?.resume(); waiting = nil
    }
    try Task.checkCancellation()
  }
  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { waiting = $0 }
  }
  func finish(failing: Bool) {
    if failing { result?.resume(throwing: PreparationError.failed) } else { result?.resume() }
    result = nil
  }
}
private enum PreparationError: Error { case failed }
@MainActor private final class PreparationFlag { var value = true }
@MainActor private final class PreparationClock {
  var now: Date
  var jobs: [UUID: (Date, @MainActor () -> Void)] = [:]
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
