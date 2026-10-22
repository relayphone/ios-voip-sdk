import Foundation
import Darwin

private enum CheckFailure: Error { case failed(String) }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw CheckFailure.failed(message) }
}

@MainActor
private final class Records {
  var values: [SDKDeviceQARecord] = []
  init() { SDKDeviceQADiagnostics.install { [weak self] in self?.values.append($0) } }
}

@main
struct DiagnosticTests {
  @MainActor private static func eventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
      try check(ContinuousClock.now < deadline, "Timed out waiting for a host diagnostic callback")
      await Task.yield()
    }
  }

  @MainActor static func main() async throws {
    let records = Records()
    try await eventsAndPrivacy(records)
    try contextRestoration()
    try await queuedDeliveryIdentity(records)
    try await completionOnce(records)
    print("{\"success\":true,\"testGroups\":4}")
  }

  @MainActor private static func eventsAndPrivacy(_ records: Records) async throws {
    let id = UUID(), secret = "synthetic-private-canary"
    let before = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    let samples = (0..<16).map { _ in VSDeviceQANanoseconds() }
    try check(samples.allSatisfy { $0 >= before } && zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 },
      "Diagnostic samples must follow the operating system monotonic clock")
    VSDeviceQAEmitPushEvent("push.ingress", id, "metadata", true)
    VSDeviceQAEmitPushEvent(secret, id, "metadata", true)
    VSDeviceQAEmitPushEvent("push.ingress", id, secret, true)
    await Task.detached {
      VSDeviceQAEmitPushEvent("push.ingress", id, "legacy", false)
    }.value
    try await eventually { records.values.count == 2 }
    let after = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    try check(before > 0 && after >= before, "The clock must be nonzero monotonic uptime")
    try check(records.values.allSatisfy { $0.event == .pushIngress && $0.deliveryID == id &&
      $0.nanoseconds >= before && $0.nanoseconds <= after }, "C fields and captured timestamps must survive Swift delivery")
    try check(records.values.contains { $0.api == .metadata && $0.mustReport == true } &&
      records.values.contains { $0.api == .legacy && $0.mustReport == false && !$0.mainThread },
      "The API, reporting policy and originating background-thread flag must be preserved")
    let domains = ["com.apple.CallKit." + secret, "com.apple.LiveCommunicationKit." + secret,
                   "NS" + secret, "VoIPSDK." + secret, secret]
    let categories = ["CallKit", "LiveCommunicationKit", "Foundation", "VoIPSDK", "other"]
    for (index, domain) in domains.enumerated() {
      SDKDeviceQADiagnostics.emit(.reportResult, conversationID: id, succeeded: false,
        error: NSError(domain: domain, code: index + 41, userInfo: [NSLocalizedDescriptionKey: secret]))
    }
    let errors = Array(records.values.suffix(5))
    try check(errors.map(\.errorDomain) == categories.map(Optional.some) &&
      errors.map(\.errorCode) == (41...45).map(Optional.some), "Only error categories and numeric codes may escape")
    SDKDeviceQADiagnostics.emit(.audioActivated)
    try check(records.values.last?.errorDomain == nil && records.values.last?.errorCode == nil,
      "An error-free event must not retain previous error fields")
    let encoded = try JSONEncoder().encode(records.values)
    try check(!String(decoding: encoded, as: UTF8.self).contains(secret),
      "Unknown C strings and arbitrary NSError data must not enter encoded diagnostics")
  }

  @MainActor private static func contextRestoration() throws {
    let outer = UUID(), inner = UUID()
    try check(VSDeviceQACurrentDeliveryID() == nil, "A delivery context must start absent")
    var observed: [UUID?] = []
    VSDeviceQAWithDelivery(outer) {
      observed.append(VSDeviceQACurrentDeliveryID() as UUID?)
      VSDeviceQAWithDelivery(inner) { observed.append(VSDeviceQACurrentDeliveryID() as UUID?) }
      observed.append(VSDeviceQACurrentDeliveryID() as UUID?)
    }
    try check(observed == [outer, inner, outer] && VSDeviceQACurrentDeliveryID() == nil,
      "Synchronous nested deliveries must restore the outer context, then remove it")
    try check(QAContextRestoresAfterException(outer, inner),
      "Objective-C exception unwinding must restore delivery context")
  }

  @MainActor private static func queuedDeliveryIdentity(_ records: Records) async throws {
    let queue = SerializedIncomingReports(), conversation = UUID()
    let deliveries = [UUID(), UUID()]
    var release: CheckedContinuation<Void, Never>?
    var enqueued: [UUID?] = [], starts: [UUID?] = [], finishes: [UUID?] = []
    var reports: [Task<UUID, Error>] = []
    for (index, delivery) in deliveries.enumerated() {
      VSDeviceQAWithDelivery(delivery) {
        let captured = VSDeviceQACurrentDeliveryID() as UUID?
        reports.append(Task { @MainActor in
          try check(VSDeviceQACurrentDeliveryID() == nil, "A Task must not depend on expired C thread context")
          return try await SDKDeviceQAPushContext.$deliveryID.withValue(captured) {
            let report = queue.enqueue(id: conversation, previouslyReported: false) { context in
              starts.append(SDKDeviceQAPushContext.deliveryID)
              SDKDeviceQADiagnostics.emit(.reportBegin, conversationID: conversation)
              if index == 0 { await withCheckedContinuation { release = $0 } }
              try check(context.previouslyReported == (index == 1), "The queued successor must observe predecessor success")
              await Task.yield()
              finishes.append(SDKDeviceQAPushContext.deliveryID)
              SDKDeviceQADiagnostics.emit(.reportResult, conversationID: conversation, succeeded: true)
              return conversation
            }
            enqueued.append(SDKDeviceQAPushContext.deliveryID)
            return try await report.value
          }
        })
      }
      if index == 0 { try await eventually { release != nil } }
    }
    try await eventually { enqueued.count == 2 }
    try check(starts == [deliveries[0]], "A queued report must wait for its predecessor")
    release?.resume()
    for report in reports { _ = try await report.value }
    try check(starts == deliveries.map(Optional.some) && finishes == starts,
      "Each delivery must retain its own TaskLocal ID across predecessor and operation suspension")
    let trace = records.values.filter { $0.conversationID == conversation }
    try check(trace.map(\.deliveryID) == [deliveries[0], deliveries[0], deliveries[1], deliveries[1]],
      "Real serialized report diagnostics must bind to the independent captured delivery IDs")
    try check(SDKDeviceQAPushContext.deliveryID == nil && queue.pending(for: conversation) == nil,
      "TaskLocal context and queue state must be restored after report settlement")
  }

  @MainActor private static func completionOnce(_ records: Records) async throws {
    let id = UUID()
    let originals: Int = await withCheckedContinuation { continuation in
      QAExerciseCompletionOnce(id) { continuation.resume(returning: $0) }
    }
    try await eventually { records.values.contains { $0.event == .pushCompletion && $0.deliveryID == id } }
    let completions = records.values.filter { $0.event == .pushCompletion && $0.deliveryID == id }
    try check(originals == 1 && completions.count == 1 && completions[0].mainThread &&
      completions[0].api == .metadata && completions[0].mustReport == true,
      "The real completion-once wrapper must emit one main-thread diagnostic and one original completion")
  }
}
