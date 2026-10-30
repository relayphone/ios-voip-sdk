import Foundation

// Deliberately withheld facade callbacks/Observation model a platform timing
// boundary. These are whole-client cache contracts, not measured LCK behavior.
@main struct IncomingCacheTests {
  @MainActor static func main() async throws {
    let mode = CommandLine.arguments[1]
    let client = try ConversationClient.forApplication(configuration: .init())
    client.finishLaunch()
    let manager = ConversationManager.latest!
    let payload = IncomingCallPayload(eventID: "cache-event-" + mode,
      serverCallID: .init(rawValue: "cache-server-" + mode),
      caller: try Caller(handleType: .generic, value: "cache-caller", displayName: "Cache fixture"),
      metadata: ["fixture": .string(mode)])
    var result: [String: Any] = ["mode": mode,
      "classification": "whole production client with platform callback timing deliberately modeled; no LCK execution"]

    func snapshotMatches(_ id: UUID) -> Bool {
      client.snapshots.count == 1 && client.snapshots.first?.id == id &&
        client.snapshots.first?.payload == payload && client.snapshots.first?.members == [payload.caller.participant]
    }
    func attempt(_ reservation: IncomingIntake.Reservation) -> IncomingIntake.Attempt {
      guard case .report(let value) = reservation.disposition else {
        preconditionFailure("Fixture requires one genuine intake report attempt.")
      }
      return value
    }

    let passed: Bool
    switch mode {
    case "reported":
      let reservation = try client.incomingIntake.reserve(payload, source: .pushKit)
      manager.conversations = [Conversation(reservation.id, state: .idle)]
      client.incomingIntake.complete(attempt(reservation), outcome: .reported)
      let before = client.snapshots.count
      let returned = try await client.reportIncomingConversation(payload)
      let after = client.snapshots.count
      passed = before == 0 && returned == reservation.id && snapshotMatches(returned)
      result.merge(["beforeCount": before, "callerCacheCount": after,
        "returnedCanonicalID": returned == reservation.id,
        "callerPayloadMatches": snapshotMatches(returned)]) { _, value in value }

    case "joined-success", "joined-sibling-success":
      let reservation = try client.incomingIntake.reserve(payload, source: .pushKit)
      var entered = false
      let caller = Task { @MainActor () throws -> (UUID, Int, Bool) in
        entered = true
        let returned = try await client.reportIncomingConversation(payload)
        // Capture directly in the caller's continuation, before any further await.
        return (returned, client.snapshots.count, snapshotMatches(returned))
      }
      while !entered { await Task.yield() }
      manager.conversations = [Conversation(reservation.id, state: .idle)]
      if mode == "joined-sibling-success" {
        let sibling = try client.incomingIntake.reserve(payload, source: .pushKit)
        client.incomingIntake.complete(attempt(reservation), outcome: .failed(PlatformFailure.rejected))
        client.incomingIntake.complete(attempt(sibling), outcome: .reported)
      } else {
        client.incomingIntake.complete(attempt(reservation), outcome: .reported)
      }
      let observed = try await caller.value
      passed = observed.0 == reservation.id && observed.1 == 1 && observed.2
      result.merge(["callerCacheCount": observed.1, "callerPayloadMatches": observed.2,
        "returnedCanonicalID": observed.0 == reservation.id]) { _, value in value }

    case "joined-failure":
      let id = try await client.reportIncomingConversation(payload)
      let seeded = snapshotMatches(id)
      // A known owned call now returns its canonical UUID. Exercise a genuinely
      // unreported invitation's failure while the separate cached call disappears.
      let native = PlatformFailure.rejected as NSError
      let duplicate = NSError(domain: "com.apple.CallKit.error.incomingcall", code: 2)
      let failures: [(error: any Error, expected: IncomingConversationError)] = [
        (PlatformFailure.rejected, .systemFailure(domain: native.domain, code: native.code)),
        (CancellationError(), .cancelled),
        (NSError(domain: "LCK-wrapper", code: 0, userInfo: [NSUnderlyingErrorKey: duplicate]), .alreadyReported),
        (IncomingIntake.IntakeError.managerReset, .providerReset)
      ]
      var allExpected = true
      var cacheCount = client.snapshots.count
      for (index, failure) in failures.enumerated() {
        var candidate = payload
        candidate.eventID += "-unreported-\(index)"; candidate.serverCallID = .init(rawValue: candidate.serverCallID.rawValue + "-unreported-\(index)")
        let unreported = candidate
        let reservation = try client.incomingIntake.reserve(unreported, source: .pushKit)
        precondition(reservation.id != id)
        var entered = false
        let caller = Task { @MainActor () -> (Bool, Int) in
          entered = true
          do throws(IncomingConversationError) {
            _ = try await client.reportIncomingConversation(unreported)
            return (false, client.snapshots.count)
          } catch {
            // Capture directly at the public await boundary, before refreshing.
            return (error == failure.expected, client.snapshots.count)
          }
        }
        while !entered { await Task.yield() }
        manager.conversations = []
        if failure.expected == .providerReset { client.incomingIntake.reset() }
        client.incomingIntake.complete(attempt(reservation), outcome: .failed(failure.error))
        let observed = await caller.value
        allExpected = allExpected && observed.0 && observed.1 == 0
        cacheCount = observed.1
      }

      // Reset can also occur during the foreground caller's own native report.
      var pendingPayload = payload
      pendingPayload.eventID += "-pending-reset"; pendingPayload.serverCallID = .init(rawValue: pendingPayload.serverCallID.rawValue + "-pending-reset")
      manager.pauseIncoming = true
      let pending = Task { @MainActor () -> Bool in
        do throws(IncomingConversationError) { _ = try await client.reportIncomingConversation(pendingPayload); return false }
        catch { return error == .providerReset }
      }
      while manager.incomingWork == nil { await Task.yield() }
      client.incomingIntake.reset()
      manager.pauseIncoming = false
      manager.incomingErrors = [PlatformFailure.rejected]
      manager.incomingWork?.resume(); manager.incomingWork = nil
      let pendingResetCaught = await pending.value
      passed = seeded && allExpected && pendingResetCaught && client.snapshots.isEmpty
      result.merge(["seededLiveCache": seeded, "callerCaughtExpectedFailure": allExpected,
        "callerCacheCount": cacheCount, "typedFailureCases": failures.count,
        "pendingReportResetCaught": pendingResetCaught]) { _, value in value }

    default: fatalError("Unknown incoming cache fixture mode.")
    }
    result["success"] = passed
    let bytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(bytes + Data([10]))
    if !passed { exit(1) }
  }
}
