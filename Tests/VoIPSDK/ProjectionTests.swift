import Foundation

@main
struct ProjectionTests {
  @MainActor static func main() async throws {
    let id = UUID()
    let terminal = SystemConversation()
    var buffer = TerminalConversationProjection<SystemConversation>()
    let first = buffer.publishTerminal(terminal, id: id)
    precondition(buffer.project(current: [:])[id] === terminal,
      "A real terminal delegate object remains projectable after the manager removes it")
    precondition(buffer.remove(id, generation: first))
    precondition(buffer.project(current: [:]).isEmpty, "Next-turn cleanup leaves no call history")
    let firstLife = SystemConversation()
    let secondLife = SystemConversation()
    let oldCleanup = buffer.publishTerminal(firstLife, id: id)
    let newCleanup = buffer.publishTerminal(secondLife, id: id)
    precondition(!buffer.remove(id, generation: oldCleanup), "An older cleanup cannot remove a newer terminal generation")
    precondition(buffer.project(current: [:])[id] === secondLife)
    precondition(buffer.remove(id, generation: newCleanup))
    let obsoleteCleanup = buffer.publishTerminal(firstLife, id: id)
    precondition(buffer.project(current: [id: secondLife])[id] === secondLife,
      "A new authoritative manager object wins over an older terminal object")
    precondition(!buffer.remove(id, generation: obsoleteCleanup) && buffer.project(current: [:]).isEmpty,
      "Invalidated terminal history cannot reappear after a reused UUID disappears")
    let listedTerminal = buffer.publishTerminal(terminal, id: id)
    precondition(buffer.remove(id, generation: listedTerminal))
    precondition(buffer.project(current: [id: terminal])[id] === terminal,
      "Cleanup must not hide a terminal object that the manager still lists")
    var cancellationSideEffects = 0
    let rejected = TerminalConversationProjection<SystemConversation>.acceptingTerminal(firstLife, current: secondLife) {
      cancellationSideEffects += 1
      return buffer.publishTerminal(firstLife, id: id)
    }
    precondition(rejected == nil && cancellationSideEffects == 0 && buffer.object(for: id) == nil,
      "An obsolete terminal delegate cannot publish or cancel a new UUID lifetime")
    let admitted = TerminalConversationProjection<SystemConversation>.acceptingTerminal(terminal, current: nil) {
      cancellationSideEffects += 1
      return buffer.publishTerminal(terminal, id: id)
    }
    precondition(admitted != nil && cancellationSideEffects == 1)
    if let admitted { buffer.remove(id, generation: admitted) }
    let queue = SerializedIncomingReports()
    var firstResume: CheckedContinuation<Void, Never>?
    var secondResume: CheckedContinuation<Void, Never>?
    var invoked: [String] = []
    let firstReport = Task { @MainActor in
      try await PushIdentity.$value.withValue("first-push") {
        try await queue.perform(id: id, previouslyReported: false) { context in
          invoked.append(PushIdentity.value ?? "missing")
          precondition(!context.previouslyReported)
          await withCheckedContinuation { firstResume = $0 }
          precondition(!context.isLatest(), "A queued successor owns cleanup")
          return id
        }
      }
    }
    while firstResume == nil { await Task.yield() }
    let secondReport = Task { @MainActor in
      try await PushIdentity.$value.withValue("second-push") {
        try await queue.perform(id: id, previouslyReported: false) { context in
          invoked.append(PushIdentity.value ?? "missing")
          precondition(context.previouslyReported && context.isLatest())
          await withCheckedContinuation { secondResume = $0 }
          return id
        }
      }
    }
    for _ in 0..<8 { await Task.yield() }
    precondition(invoked == ["first-push"] && secondResume == nil)
    firstResume?.resume()
    _ = try await firstReport.value
    while secondResume == nil { await Task.yield() }
    precondition(queue.pending(for: id) != nil && invoked == ["first-push", "second-push"])
    secondResume?.resume()
    _ = try await secondReport.value
    precondition(queue.pending(for: id) == nil)
    var failedResume: CheckedContinuation<Void, Never>?
    let failedFirst = Task { @MainActor in
      try await queue.perform(id: id, previouslyReported: false) { context in
        precondition(!context.previouslyReported)
        await withCheckedContinuation { failedResume = $0 }
        precondition(!context.isLatest())
        throw ReportFailure.failed
      }
    }
    while failedResume == nil { await Task.yield() }
    let following = Task { @MainActor in
      try await queue.perform(id: id, previouslyReported: false) { context in
        precondition(!context.previouslyReported && context.isLatest(),
          "A failed predecessor cannot turn an unreported invitation into a tombstone")
        return id
      }
    }
    for _ in 0..<8 { await Task.yield() }
    failedResume?.resume()
    do { _ = try await failedFirst.value; preconditionFailure("Failed report unexpectedly succeeded") }
    catch ReportFailure.failed {}
    _ = try await following.value
    precondition(queue.pending(for: id) == nil)
    do {
      _ = try await queue.perform(id: id, previouslyReported: true) { context in
        precondition(context.previouslyReported)
        throw ReportFailure.failed
      }
      preconditionFailure("Historical attempt unexpectedly succeeded")
    } catch ReportFailure.failed {}
    precondition(queue.pending(for: id) == nil, "Failed reports also own immediate cleanup")
    // A new UUID reaches its actual operation in this Task, without an internal
    // child Task or predecessor hop. Unrelated UUIDs need not await a blocked report.
    let unrelatedID = UUID()
    var reached = false
    _ = try await queue.perform(id: unrelatedID, previouslyReported: false) { _ in reached = true; return unrelatedID }
    precondition(reached && queue.pending(for: unrelatedID) == nil)
    print("Terminal projection and incoming report serialization tests passed")
  }
}
final class SystemConversation {}

enum PushIdentity { @TaskLocal static var value: String? }

enum ReportFailure: Error { case failed }
