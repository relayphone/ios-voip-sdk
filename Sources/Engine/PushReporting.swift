// PushKit reporting policy shared by the simulator engine and the host tests.
#if os(macOS) || (os(iOS) && targetEnvironment(simulator))
  import Foundation

  struct PushReportingProfile: Decodable, Sendable {
    enum ApplicationState: String, Sendable { case launching, foreground, background, unknown }
    enum Verification: String, Decodable, Sendable { case verified, unverified }
    struct Rule: Decodable, Sendable {
      let seconds: Double
      let verification: Verification
      let evidence: [String]
    }
    let foregroundOrLaunch: Rule
    let backgroundJoinedCall: Rule
    let fallback: Rule

    func rule(application: ApplicationState, joinedCall: Bool) -> Rule {
      switch (application, joinedCall) {
      case (.launching, _), (.foreground, false): foregroundOrLaunch
      case (.background, true): backgroundJoinedCall
      default: fallback
      }
    }

    var valid: Bool {
      [foregroundOrLaunch, backgroundJoinedCall, fallback].allSatisfy {
        $0.seconds.isFinite && $0.seconds > 0 && !$0.evidence.isEmpty
      } && foregroundOrLaunch.verification == .verified
        && backgroundJoinedCall.verification == .verified && fallback.verification == .unverified
    }
  }

  // A new UUID can satisfy at most one delivery. Callback return and completion are diagnostics;
  // neither ends the reporting window. Times are monotonic offsets supplied by the caller.
  struct PushReportingObligations {
    struct Observation {
      let required: Bool
      let reportEntered: Bool
      let violation: String?
    }
    private struct Delivery {
      let required: Bool
      let token = UUID()
      let deadline: Duration
      let order: UInt64
      var reportEntered = false
      var returned = false
      var completed = false
    }
    private var deliveries: [String: Delivery] = [:]
    private var reportedCalls = Set<UUID>()
    private var order: UInt64 = 0

    mutating func receive(_ id: String, required: Bool, now: Duration, budget: Duration) -> Bool {
      guard !id.isEmpty, deliveries[id] == nil else { return false }
      order += 1
      deliveries[id] = Delivery(required: required, deadline: now + budget, order: order)
      return true
    }

    mutating func entered(_ id: String, call: UUID, alreadyKnown: Bool, now: Duration) -> Bool {
      let fresh = reportedCalls.insert(call).inserted && !alreadyKnown
      guard fresh, var delivery = deliveries[id], now < delivery.deadline,
        !delivery.reportEntered
      else { return false }
      delivery.reportEntered = true
      if delivery.returned && delivery.completed {
        deliveries.removeValue(forKey: id)
      } else {
        deliveries[id] = delivery
      }
      return true
    }

    func deadlineToken(_ id: String) -> UUID? { deliveries[id]?.token }

    // LCK enters reports on its own queue. In the absence of thread-local attribution, consume
    // the oldest outstanding obligation, including after its callback returned. This ordering
    // is simulator policy; one new report must never discharge several concurrent pushes.
    func awaitingReport() -> String? {
      deliveries.filter { $0.value.required && !$0.value.reportEntered }
        .min { $0.value.order < $1.value.order }?.key
    }

    mutating func expire(_ id: String, token: UUID, now: Duration) -> Bool {
      guard let delivery = deliveries[id], delivery.token == token, delivery.required,
        !delivery.reportEntered, now >= delivery.deadline
      else { return false }
      deliveries.removeValue(forKey: id)
      return true
    }
    mutating func returned(_ id: String) -> Observation { observe(id, completion: false) }
    mutating func completed(_ id: String) -> Observation { observe(id, completion: true) }

    private mutating func observe(_ id: String, completion: Bool) -> Observation {
      guard var delivery = deliveries[id] else {
        return Observation(required: false, reportEntered: false, violation: "unknown-delivery")
      }
      let repeated = completion ? delivery.completed : delivery.returned
      if completion { delivery.completed = true } else { delivery.returned = true }
      let violation =
        repeated
        ? "repeated-" + (completion ? "completion" : "callback-return")
        : delivery.required && !delivery.reportEntered
          ? "required-report-missing-at-" + (completion ? "completion" : "callback-return") : nil
      if delivery.completed && delivery.returned && (!delivery.required || delivery.reportEntered) {
        deliveries.removeValue(forKey: id)
      } else {
        deliveries[id] = delivery
      }
      return Observation(
        required: delivery.required, reportEntered: delivery.reportEntered, violation: violation)
    }
  }
#endif
