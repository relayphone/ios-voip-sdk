import CallKit
import Foundation

// Exercises real CallKit objects in the running app. Queue suspension and
// completion reentrancy place invalidation at exact lifecycle boundaries.
final class GenerationProbe: NSObject, CXProviderDelegate, @unchecked Sendable {
  private let queue = DispatchQueue(label: "probe.generations.delegate")
  private let controller = CXCallController(queue: DispatchQueue(label: "probe.generations.controller"))
  private let observer = CXCallObserver()
  private let provider = CXProvider(configuration: CXProviderConfiguration())
  private let lock = NSLock()
  private var performed = Set<UUID>()
  private var failedAnswer = false
  private var heldAnswer = false
  private var unexpectedUnmutes = 0

  private func report(_ id: UUID) {
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: "generation-probe")
    provider.reportNewIncomingCall(with: id, update: update) { error in
      Trace.shared.log("generation.report", ["result": describe(error)])
    }
  }
  private func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
  private func hasPerformed(_ id: UUID) -> Bool {
    lock.lock(); defer { lock.unlock() }; return performed.contains(id)
  }
  private func waitFor(_ action: CXAction) async {
    for _ in 0..<200 {
      if hasPerformed(action.uuid) { return }
      await sleep(0.01)
    }
    preconditionFailure("Generation probe action never reached delegate")
  }
  private func request(_ action: CXAction, beforeReturn: (@Sendable () -> Void)? = nil) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      controller.request(CXTransaction(action: action)) { error in
        precondition(error == nil)
        beforeReturn?()
        continuation.resume()
      }
    }
  }
  private func check(_ name: String, _ success: Bool) {
    Trace.shared.log("generation.check", ["name": name, "success": success])
    precondition(success, name)
  }
  func run() async {
    provider.setDelegate(self, queue: queue)
    let id = UUID()
    report(id)
    let continuationAction = CXSetMutedCallAction(call: id, muted: true)
    await request(continuationAction) {
      self.provider.invalidate()
      self.report(id)
    }
    await sleep(0.2)
    check("completion continuation cancelled after revival", !hasPerformed(continuationAction.uuid))

    let reusedAction = CXSetMutedCallAction(call: id, muted: true)
    await request(reusedAction) {
      self.provider.reportCall(with: id, endedAt: Date(), reason: .remoteEnded)
      self.report(id)
    }
    await sleep(0.2)
    check("completion continuation cannot mutate reused UUID", !hasPerformed(reusedAction.uuid))

    queue.suspend()
    let queuedAction = CXSetMutedCallAction(call: id, muted: true)
    await request(queuedAction)
    // pendingTransactions is filled before the delegate block is queued.
    for _ in 0..<200 {
      if !provider.pendingTransactions.isEmpty { break }
      await sleep(0.01)
    }
    let queued = !provider.pendingTransactions.isEmpty
    provider.invalidate(); report(id)
    queue.resume()
    await sleep(0.2)
    check("delegate callback cancelled after revival", queued && !hasPerformed(queuedAction.uuid))

    let muted = CXSetMutedCallAction(call: id, muted: true)
    await request(muted); await waitFor(muted)
    provider.invalidate(); report(id)
    await sleep(0.2)
    check("muted invalidation produces no stale unmute", queue.sync { unexpectedUnmutes == 0 })

    let mutedAgain = CXSetMutedCallAction(call: id, muted: true)
    await request(mutedAgain); await waitFor(mutedAgain)
    // Schedule the producer while valid, then change the provider generation.
    // A different UUID ensures the call-incarnation guard cannot mask it.
    provider.reportCall(with: id, endedAt: Date(), reason: .remoteEnded)
    provider.invalidate()
    let otherID = UUID()
    report(otherID)
    await sleep(0.2)
    check("queued unmute producer cancelled after revival", queue.sync { unexpectedUnmutes == 0 })
    provider.reportCall(with: otherID, endedAt: Date(), reason: .remoteEnded)
    report(id)

    queue.sync { failedAnswer = true }
    let failed = CXAnswerCallAction(call: id)
    await request(failed); await waitFor(failed)
    // Reuse the UUID within the failed answer's delayed end window.
    provider.reportCall(with: id, endedAt: Date(), reason: .remoteEnded); report(id)
    await sleep(0.5)
    check("failed answer cannot end reused UUID", observer.calls.contains { $0.uuid == id && !$0.hasEnded })

    queue.sync { failedAnswer = false; heldAnswer = true }
    let unanswered = CXAnswerCallAction(call: id)
    await request(unanswered); await waitFor(unanswered)
    provider.reportCall(with: id, endedAt: Date(), reason: .remoteEnded); report(id)
    queue.sync { heldAnswer = false }
    let freshAnswer = CXAnswerCallAction(call: id)
    await request(freshAnswer); await waitFor(freshAnswer)
    await sleep(60.2)
    check("expired answer cannot end reused UUID", observer.calls.contains { $0.uuid == id && !$0.hasEnded })
    provider.reportCall(with: id, endedAt: Date(), reason: .remoteEnded)
    provider.invalidate()
    Trace.shared.log("done")
  }
  func providerDidReset(_ provider: CXProvider) {}
  private func finish(_ action: CXAction, fail: Bool = false, hold: Bool = false) {
    Trace.shared.log("generation.perform", ["actionID": action.uuid.uuidString, "kind": NSStringFromClass(type(of: action))])
    if !hold { if fail { action.fail() } else { action.fulfill() } }
    lock.lock(); performed.insert(action.uuid); lock.unlock()
  }
  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    if !action.isMuted { unexpectedUnmutes += 1 }
    finish(action)
  }
  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) { finish(action, fail: failedAnswer, hold: heldAnswer) }
  func provider(_ provider: CXProvider, perform action: CXEndCallAction) { finish(action) }
}
