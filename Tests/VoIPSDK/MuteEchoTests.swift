import Dispatch
import Foundation

@MainActor
final class MuteControls {
  let client: ConversationClient
  let manager: ConversationManager
  var calls: [ConversationActionContext] = []
  var held: [UUID: CheckedContinuation<Void, any Error>] = [:]
  var minimumDelayMS = Double.infinity

  init() throws {
    client = try ConversationClient.forApplication(configuration: .init())
    client.finishLaunch()
    manager = ConversationManager.latest!
    client.setConversationHandler(.init(join: { _, _ in }, start: { _, _ in }, end: { _, _ in },
      mute: { [weak self] _, context in
        guard let self else { preconditionFailure("Control lifetime ended") }
        self.calls.append(context)
        try await withCheckedThrowingContinuation { self.held[context.actionID] = $0 }
      }))
  }
  func conversation() async throws -> UUID {
    try await client.startConversation(to: .init(id: "host-mute-fixture"))
  }
  func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition() {
      precondition(ContinuousClock.now < deadline, "Host boundary did not reach expected state")
      try await Task.sleep(for: .milliseconds(1))
    }
  }
  func begin(_ id: UUID, _ value: Bool) async throws -> (Task<Void, any Error>, ConversationAction, ConversationActionContext) {
    let count = calls.count
    let task = Task { try await self.client.setMuted(id, value) }
    try await wait { self.calls.count > count }
    let context = calls.last!
    precondition(context.origin == .app && context.muted == value)
    return (task, manager.appActions.last!, context)
  }
  func delayedEcho(_ id: UUID, value: Bool, appAction: ConversationAction,
                   context: ConversationActionContext, group: String) async throws -> MuteConversationAction {
    let before = DispatchTime.now().uptimeNanoseconds
    try await Task.sleep(for: .milliseconds(40))
    let delay = Double(DispatchTime.now().uptimeNanoseconds - before) / 1_000_000
    precondition(delay >= 40, "Host handler must remain pending beyond the measured device echo interval")
    minimumDelayMS = min(minimumDelayMS, delay)
    let remainingMS = context.deadline.timeIntervalSinceNow * 1000
    let pending = client.snapshots.first { $0.id == id }?.pending
    let diagnostic = "group=\(group) app=\(appAction.uuid) context=\(context.actionID) " +
      "state=\(appAction.state) settlements=\(appAction.settlements) remainingMS=\(remainingMS) " +
      "signal=\(context.signal.reason?.rawValue ?? "none") pending=\(String(describing: pending?.id)) calls=\(calls.count)"
    precondition(!group.isEmpty && appAction.conversationUUID == id && appAction.uuid == context.actionID &&
      context.origin == .app && context.muted == value &&
      (appAction as? MuteConversationAction)?.isMuted == value && appAction.state == .running &&
      appAction.settlements == 0 && !context.signal.isCancelled && remainingMS > 0 && pending?.id == appAction.uuid,
      "Matching echo fixture requires the exact live, unexpired app mute immediately before delivery: \(diagnostic)")
    let count = calls.count
    let echo = system(id, value)
    precondition(echo.state == .complete && echo.settlements == 1 && calls.count == count,
      "Matching system echo must fulfill inline at the synchronous host boundary: \(diagnostic) echo=\(echo.state)/\(echo.settlements) calls=\(calls.count)")
    for _ in 0..<8 { await Task.yield() }
    precondition(echo.state == .complete && echo.settlements == 1 && calls.count == count,
      "Matching system echo must not invoke a second handler while app mute is pending: \(diagnostic) echo=\(echo.state)/\(echo.settlements) calls=\(calls.count)")
    return echo
  }
  func system(_ id: UUID, _ value: Bool) -> MuteConversationAction {
    let action = MuteConversationAction(conversationUUID: id, isMuted: value)
    manager.deliver(action)
    return action
  }
  func resume(_ id: UUID, accepted: Bool = true) {
    guard let continuation = held.removeValue(forKey: id) else { preconditionFailure("Missing handler continuation") }
    if accepted { continuation.resume() } else { continuation.resume(throwing: PlatformFailure.rejected) }
  }
  func rejected(_ task: Task<Void, any Error>) async {
    do { try await task.value; preconditionFailure("Platform action should fail") }
    catch PlatformFailure.rejected {}
    catch { preconditionFailure("Unexpected host boundary error") }
  }
  func genuineAfterCleanup(_ id: UUID, stale: UUID) async throws {
    let count = calls.count
    let next = system(id, true)
    try await wait { self.calls.count == count + 1 }
    precondition(calls.last?.origin == .system && calls.last?.muted == true)
    // Release obsolete application work while the new system action is pending.
    if held[stale] != nil { resume(stale) }
    for _ in 0..<8 { await Task.yield() }
    precondition(next.state == .running && client.snapshots.first { $0.id == id }?.isMuted == false,
      "A late result cannot resurrect settled app work or settle a new action")
    resume(next.uuid)
    try await wait { next.state == .complete }
    precondition(next.settlements == 1 && client.snapshots.first { $0.id == id }?.isMuted == true)
  }

  func run() async throws {
    // The opposite system value equals committed state here. It is still genuine
    // because app work with the other value remains pending.
    let id = try await conversation()
    let (app, appAction, context) = try await begin(id, true)
    _ = try await delayedEcho(id, value: true, appAction: appAction, context: context, group: "accepted")
    let count = calls.count
    let opposite = system(id, false)
    try await wait { self.calls.count == count + 1 }
    precondition(calls.last?.origin == .system && calls.last?.muted == false && opposite.state == .running)
    resume(opposite.uuid)
    try await wait { opposite.state == .complete }
    resume(context.actionID)
    try await app.value
    let after = calls.count
    let settledEcho = system(id, true)
    precondition(settledEcho.state == .complete && calls.count == after,
      "The established-state no-op filter remains intact after app fulfillment")

    let rejectedID = try await conversation()
    let (rejectedApp, rejectedAction, rejectedContext) = try await begin(rejectedID, true)
    _ = try await delayedEcho(rejectedID, value: true, appAction: rejectedAction, context: rejectedContext, group: "rejected")
    resume(rejectedContext.actionID, accepted: false)
    await rejected(rejectedApp)
    precondition(client.snapshots.first { $0.id == rejectedID }?.pending == nil)
    try await genuineAfterCleanup(rejectedID, stale: rejectedContext.actionID)

    let timeoutID = try await conversation()
    manager.nextTimeout = 1.62
    let previousActions = manager.appActions.count
    let timedApp = Task { try await self.client.setMuted(timeoutID, true) }
    try await wait { self.manager.appActions.count == previousActions + 1 }
    let timedAction = manager.appActions.last!
    // Expiry may correctly precede handler dispatch. The normal-budget groups
    // above require live held handlers; this short-deadline group requires expiry.
    try await wait { timedAction.state == .failed }
    await rejected(timedApp)
    precondition(timedAction.settlements == 1 && client.snapshots.first { $0.id == timeoutID }?.pending == nil)
    if let context = calls.first(where: { $0.actionID == timedAction.uuid }) {
      precondition(context.signal.reason == .deadline)
    }
    try await genuineAfterCleanup(timeoutID, stale: timedAction.uuid)

    let platformID = try await conversation()
    let (platformApp, platformAction, platformContext) = try await begin(platformID, true)
    platformAction.fail()
    manager.delegate?.conversationManager(manager, timedOutPerforming: platformAction)
    await rejected(platformApp)
    precondition(platformContext.signal.reason == .platformTimeout)
    try await genuineAfterCleanup(platformID, stale: platformContext.actionID)

    let resetID = try await conversation()
    let (resetApp, resetAction, resetContext) = try await begin(resetID, true)
    manager.delegate?.conversationManagerDidReset(manager)
    await rejected(resetApp)
    precondition(resetContext.signal.reason == .reset && resetAction.settlements == 1)
    try await genuineAfterCleanup(resetID, stale: resetContext.actionID)

    // A platform-settled entry can remain until the coordinator hears about it.
    // It must not supply a pending intent to the echo filter in that interval.
    let settledID = try await conversation()
    let (settledApp, settledAction, settledContext) = try await begin(settledID, true)
    settledAction.fail()
    await rejected(settledApp)
    try await genuineAfterCleanup(settledID, stale: settledContext.actionID)

    let otherID = try await conversation()
    let independentID = try await conversation()
    let (otherApp, _, otherContext) = try await begin(otherID, true)
    let beforeIndependent = calls.count
    let independent = system(independentID, true)
    try await wait { self.calls.count == beforeIndependent + 1 }
    resume(independent.uuid)
    try await wait { independent.state == .complete }
    resume(otherContext.actionID)
    try await otherApp.value
    precondition(held.isEmpty, "Every delayed handler continuation must be released")
    print("{\"success\":true,\"groups\":7,\"minimumPendingHandlerDelayMS\":\(minimumDelayMS),\"actualClientAndHandler\":true,\"nativeDeviceTimingMeasured\":false}")
  }
}

@main struct MuteEchoTests {
  @MainActor static func main() async throws { try await MuteControls().run() }
}
