import Foundation

struct RuntimeTimingReadout: Codable, Identifiable {
  let id: String
  let title: String
  let actualLabel: String
  let actualMS: Double?
  let startSequence: Int?
  let endSequence: Int?
  let deviceValue: String
  let deviceProvenance: String
  let sourcePath: String

  var actualValue: String {
    actualMS.map { String(format: "%.1f ms", $0) } ?? "Unavailable"
  }
}

enum RuntimeTimingReferences {
  private struct Interval {
    let start: RuntimeEvent
    let end: RuntimeEvent
    var milliseconds: Double { end.t_ms - start.t_ms }
  }

  static func project(_ timeline: [RuntimeEvent]) -> [RuntimeTimingReadout] {
    let push = timeline.last { $0.event == "push.received" }
    let report = interval(from: push, in: timeline) { start, end in
      end.event == "report.completed" && end.reportSucceeded && nonempty(start.pushID) && start.pushID == end.pushID
    }
    let expired = interval(from: push, in: timeline) { start, end in
      start.mustReport == true && end.event == "diagnostic.pushReportExpired" &&
        nonempty(start.pushID) && start.pushID == end.pushID
    }
    let answer = timeline.last { $0.event == "action.deadline" && $0.kind == "answer" }
    let candidateAudio = interval(from: answer, in: timeline) { start, end in
      nonempty(start.actionID) && nonempty(start.callUUID) && apiLabel(start.apiKind) != nil && end.event == "audio.activated"
    }
    let audio = candidateAudio.flatMap { candidate in
      guard timeline.contains(where: { row in
        row.sequence > candidate.start.sequence && row.sequence < candidate.end.sequence &&
          row.runID == candidate.start.runID && row.pid == candidate.start.pid && row.bundleID == candidate.start.bundleID &&
          row.event == "action.settled" && row.kind == "answer" && row.fulfilled == true &&
          row.actionID == candidate.start.actionID && row.callUUID == candidate.start.callUUID && row.apiKind == candidate.start.apiKind
      }), !timeline.contains(where: { invalidatesAudio($0, between: candidate) }) else { return nil as Interval? }
      return candidate
    }
    let mute = timeline.last { $0.event == "action.settled" && $0.kind == "mute" && $0.origin == "application" }
    let candidateEcho = interval(from: mute, in: timeline) { start, end in
      start.fulfilled == true && end.event == "action.deadline" && end.kind == "mute" && end.origin == "muteEcho" &&
        nonempty(start.actionID) && nonempty(start.transactionID) && nonempty(end.actionID) && nonempty(end.transactionID) &&
        nonempty(start.callUUID) && start.callUUID == end.callUUID &&
        muteValue(start, in: timeline) != nil && muteValue(start, in: timeline) == muteValue(end, in: timeline) &&
        apiLabel(start.apiKind) != nil && start.apiKind == end.apiKind &&
        nonempty(start.provider) && start.provider == end.provider
    }
    let echo = candidateEcho.flatMap { muteEchoIsUnambiguous($0, in: timeline) ? $0 : nil }
    let answerLabel = answer.flatMap { apiLabel($0.apiKind) }.map { "Simulator · \($0) delivered → audio.activated" }
      ?? "Simulator · answer / join → audio.activated (API unavailable)"
    return [
      readout("pushReport", "Push → report done", "Simulator · push → report done", "≈190 ms", "Cold launch, locked · report succeeded", report),
      readout("answerAudio", "Answer / join → audio activation", answerLabel, "≈236 ms", "Join callback → didActivate", audio),
      readout("muteEcho", "Mute fulfillment → system echo", "Simulator · app fulfillment → mute echo", "8–17 ms after fulfillment", "App mute / unmute fulfilled → MuteConversationAction", echo),
      readout("unreportedPush", "Unreported PushKit deadline", "Simulator · push → report-expiry diagnostic", "≈4.4 s", "Unreported push · observed SIGABRT termination", expired)
    ]
  }

  private static func nonempty(_ value: String?) -> Bool { value?.isEmpty == false }

  private static func apiLabel(_ value: String?) -> String? {
    switch value {
    case "callkit": return "CallKit answer"
    case "livecommunicationkit": return "LCK join"
    default: return nil
    }
  }

  // Native action rows omit the value; the delivered transaction records it once.
  private static func muteValue(_ action: RuntimeEvent, in timeline: [RuntimeEvent]) -> Bool? {
    guard nonempty(action.actionID), nonempty(action.transactionID), nonempty(action.provider),
          nonempty(action.callUUID), nonempty(action.origin), action.t_ms.isFinite else { return nil }
    let transactions = timeline.filter {
      $0.event == "transaction.delivered" && $0.transactionID == action.transactionID &&
        $0.schemaVersion == action.schemaVersion && $0.runID == action.runID &&
        $0.pid == action.pid && $0.bundleID == action.bundleID
    }
    guard !transactions.isEmpty else { return action.muted }
    guard transactions.count == 1, let transaction = transactions.first,
          transaction.provider == action.provider, transaction.origin == action.origin,
          transaction.sequence < action.sequence, transaction.t_ms.isFinite, transaction.t_ms <= action.t_ms,
          let ids = transaction.actionIDs, !ids.isEmpty, ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count,
          let calls = transaction.callUUIDs, calls.count == ids.count, calls.allSatisfy({ !$0.isEmpty }),
          let kinds = transaction.kinds, kinds.count == ids.count, kinds.allSatisfy({ !$0.isEmpty }),
          let parameters = transaction.parameters, parameters.count == ids.count,
          let index = ids.firstIndex(of: action.actionID!), calls[index] == action.callUUID,
          kinds[index] == "CXSetMutedCallAction", let value = parameters[index].muted,
          action.muted == nil || action.muted == value else { return nil }
    return value
  }

  // Echo actions carry fresh IDs rather than their originating action ID.
  // Count obligations without assuming an ordering relationship between echoes.
  private static func muteEchoIsUnambiguous(_ interval: Interval, in timeline: [RuntimeEvent]) -> Bool {
    guard timeline.first?.sequence == 1 else { return false }
    let start = interval.start
    guard let value = muteValue(start, in: timeline) else { return false }
    var outstanding = 0
    var fulfilledIDs = Set<String>()
    var deliveredIDs = Set<String>()
    for row in timeline where row.sequence < interval.end.sequence {
      guard row.runID == start.runID, row.pid == start.pid, row.bundleID == start.bundleID,
            row.schemaVersion == start.schemaVersion else { continue }
      if row.event == "action.deadline", row.actionID == interval.end.actionID { return false }
      if row.sequence < start.sequence, row.event == "action.settled", row.fulfilled == true,
         row.actionID == start.actionID { return false }
      // A delivery ID is consumed even when its value is irrelevant to this pair.
      let firstDelivery: Bool
      if row.event == "action.deadline", let id = row.actionID, !id.isEmpty {
        firstDelivery = deliveredIDs.insert(id).inserted
      } else { firstDelivery = false }
      guard row.kind == "mute", row.callUUID == start.callUUID,
            row.apiKind == start.apiKind, row.provider == start.provider else { continue }
      let fulfillment = row.event == "action.settled" && row.origin == "application" && row.fulfilled == true
      let echo = row.event == "action.deadline" && row.origin == "muteEcho"
      guard fulfillment || echo else { continue }
      guard let rowValue = muteValue(row, in: timeline) else { return false }
      guard rowValue == value else { continue }
      if row.sequence < start.sequence {
        if fulfillment {
          guard let id = row.actionID, !id.isEmpty, nonempty(row.transactionID) else { return false }
          guard id != start.actionID else { return false }
          if fulfilledIDs.insert(id).inserted { outstanding += 1 }
        } else if echo, firstDelivery, nonempty(row.transactionID) {
          outstanding = max(0, outstanding - 1)
        }
      } else if row.sequence > start.sequence, fulfillment, row.actionID != start.actionID {
        return false
      }
    }
    return outstanding == 0 && !deliveredIDs.contains(interval.end.actionID ?? "")
  }

  // Audio activation is process-wide in the journal. An intervening audio trigger
  // or invalidation makes attribution to this answer unsafe.
  private static func invalidatesAudio(_ row: RuntimeEvent, between interval: Interval) -> Bool {
    let start = interval.start
    guard row.sequence > start.sequence, row.sequence < interval.end.sequence,
          row.runID == start.runID, row.pid == start.pid, row.bundleID == start.bundleID else { return false }
    if ["provider.reset", "provider.invalidated", "audio.failed", "fault.audioSuppressed", "report.connected"].contains(row.event) { return true }
    if ["action.deadline", "action.settled"].contains(row.event), ["start", "hold", "end"].contains(row.kind) { return true }
    if ["action.deadline", "action.settled"].contains(row.event), row.kind == "answer", row.actionID != start.actionID { return true }
    if row.event == "call.changed", row.uuid == start.callUUID, row.ended == true { return true }
    if row.actionID == start.actionID {
      return ["action.expired", "action.timeout", "action.cancelled"].contains(row.event) ||
        (row.event == "action.settled" && row.fulfilled == false)
    }
    return false
  }

  private static func interval(from start: RuntimeEvent?, in timeline: [RuntimeEvent],
                               matching: (RuntimeEvent, RuntimeEvent) -> Bool) -> Interval? {
    guard let start, start.t_ms.isFinite else { return nil }
    guard let end = timeline.first(where: {
      $0.sequence > start.sequence && $0.runID == start.runID && $0.pid == start.pid &&
        $0.bundleID == start.bundleID && $0.schemaVersion == start.schemaVersion && matching(start, $0)
    }), end.t_ms.isFinite, end.t_ms >= start.t_ms,
       (end.t_ms - start.t_ms).isFinite else { return nil }
    return .init(start: start, end: end)
  }

  private static func readout(_ id: String, _ title: String, _ actualLabel: String,
                              _ deviceValue: String, _ context: String, _ interval: Interval?) -> RuntimeTimingReadout {
    .init(id: id, title: title, actualLabel: actualLabel, actualMS: interval?.milliseconds,
      startSequence: interval?.start.sequence, endSequence: interval?.end.sequence, deviceValue: deviceValue,
      deviceProvenance: "LCK · iPhone 13 · iOS 27.0 · Oct 23, 2026 · \(context)",
      sourcePath: "docs/research/callkit-simulator-probe/livecommunicationkit/push/README.md")
  }
}
