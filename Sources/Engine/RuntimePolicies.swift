// The runtime's measured policies and its behaviour profile. They depend only on Foundation, so the
// host tests exercise them without a simulator; device builds never compile them.
#if os(macOS) || (os(iOS) && targetEnvironment(simulator))
  import Foundation
  #if SWIFT_PACKAGE
    import CKSimProtocol
  #endif

  enum ProviderAPIKind: String { case callkit, livecommunicationkit }
  struct FulfilledPostEndUnmutePolicy: Decodable {
    enum Settlement: String, Decodable { case timeout, complete }
    let callkit: Settlement
    let livecommunicationkit: Settlement
    func settlement(for api: ProviderAPIKind) -> Settlement {
      switch api {
      case .callkit: callkit
      case .livecommunicationkit: livecommunicationkit
      }
    }
  }
  typealias IncomingFilterReason = ControlRequest.FilterReason
  extension ControlRequest.FilterReason {
    var code: Int {
      switch self {
      case .none: 0
      case .doNotDisturb: 3
      case .restrictedSharingMode: 5
      case .callIsProtected: 6
      case .sensitiveParticipants: 7
      }
    }
    func snapshot(policy: IncomingFilterPolicy?) -> [String: Any] {
      ["reason": rawValue, "code": code, "verification": policy?.verification ?? "not-applicable"]
    }
  }
  struct IncomingFilterPolicy: Decodable, Sendable {
    let code: Int
    let delaySeconds: Double
    let verification: String
    let evidence: [String]
  }
  // Immutable per-report decision: later filter/fault commands cannot change an
  // entered report. Duplicate UUID errors retain their existing code-2 priority.
  struct IncomingReportOutcome: Sendable {
    let code: Int
    let domain: String
    let filterReason: String
    let verification: String
    let delaySeconds: Double
    var error: NSError? { code == 0 ? nil : NSError(domain: domain, code: code) }
    init(
      reason: IncomingFilterReason, duplicate: Bool, policy: IncomingFilterPolicy?,
      normalDelaySeconds: Double, extraDelaySeconds: Double, incomingErrorCode: Int = 0
    ) {
      if duplicate {
        code = 2
        filterReason = "none"
        verification = "not-applicable"
        delaySeconds = normalDelaySeconds + extraDelaySeconds
      } else if incomingErrorCode == 4 {
        code = 4
        filterReason = "none"
        verification = "injected-fault"
        delaySeconds = normalDelaySeconds + extraDelaySeconds
      } else if reason != .none, let policy {
        code = reason.code
        filterReason = reason.rawValue
        verification = policy.verification
        delaySeconds = policy.delaySeconds + extraDelaySeconds
      } else {
        code = 0
        filterReason = "none"
        verification = "not-applicable"
        delaySeconds = normalDelaySeconds + extraDelaySeconds
      }
      domain = code == 0 ? "" : "com.apple.CallKit.error.incomingcall"
    }
  }
  // iPhone 13 / iOS 27.0, #85. LCK exposes no group membership or transaction IDs.
  struct LCKMultiCallPolicy {
    enum Kind { case join, pause, resume, end, merge, other }
    enum Failure { case endWithCleanup, endRegardless, none }
    static func failure(_ kind: Kind) -> Failure {
      switch kind {
      case .join, .pause: .endWithCleanup
      case .end: .endRegardless
      default: .none
      }
    }
    static func choices(established: Int, held: Int, active: Int, maximumGroups: Int) -> [String] {
      if established == 0 { return ["answer", "decline"] }
      guard active == 1 else { return [] }  // This configuration was not measured.
      var result = ["end-and-accept", "decline"]
      if maximumGroups >= 2 && established < maximumGroups {
        result.insert("hold-and-accept", at: 0)
      }
      if held > 0 { result.append("end-held-and-accept") }
      return result
    }
    static func canStart(established: Int, reservedStarts: Int, maximumGroups: Int) -> Bool {
      established + reservedStarts < maximumGroups
    }
    static func shouldEndActiveOnResume(maximumGroups: Int, maximumPerGroup: Int) -> Bool {
      maximumGroups == 2 && maximumPerGroup == 1
    }
    static func resumeEndDelay(nominal: Double, elapsedSinceIssued: Double) -> Double {
      max(0, nominal - elapsedSinceIssued)
    }
    static func usesCompositeBarrier(system: Bool, actionCount: Int, joiningCount: Int) -> Bool {
      system && actionCount > 1 && joiningCount > 0
    }
    struct Handoff {
      private var gapElapsed = false
      private var joined = false
      mutating func markGapElapsed() -> Bool {
        gapElapsed = true
        return joined
      }
      mutating func markJoined() -> Bool {
        joined = true
        return gapElapsed
      }
    }
    struct Barrier {
      private var remaining: Set<UUID>
      private let joining: [UUID: UUID]
      private var failed = Set<UUID>()
      init(actions: [UUID], joining: [UUID: UUID]) {
        remaining = Set(actions)
        self.joining = joining
      }
      mutating func settle(_ action: UUID, fulfilled: Bool) -> [UUID]? {
        guard remaining.remove(action) != nil else { return nil }
        if !fulfilled { failed.insert(action) }
        guard remaining.isEmpty else { return nil }
        return joining.filter { !failed.contains($0.key) }.map(\.value)
      }
    }
  }
  struct LCKMultiCallProfile: Decodable {
    let pauseEndExpirySeconds: Double
    let joinExpirySeconds: Double
    let cleanupEndExpirySeconds: Double
    let pausedAfterDeliverySeconds: Double
    let joinedAfterSettlementSeconds: Double
    let audioHandoffGapSeconds: Double
    let audioDeactivationAfterDeliverySeconds: Double
    let appResumeEndDelaySeconds: Double
  }
  struct BehaviorProfile: Decodable {
    let id: String
    let schemaVersion: Int
    let answerExpirySeconds: Double
    let ringTimeoutSeconds: Double
    let unknownProviderSeconds: Double
    let actionTimeoutSeconds: Double
    let startDeadlineSeconds: Double
    let answerDeadlineSeconds: Double
    let ordinaryDeadlineSeconds: Double
    let lckActionDeadlineSeconds: Double
    let lckMultiCall: LCKMultiCallProfile
    let reportLatencySeconds: Double
    let pushReportDeadlineSeconds: Double
    let incomingFilterPolicies: [String: IncomingFilterPolicy]
    let muteEchoSeconds: Double
    let postEndUnmuteSeconds: Double
    let fulfilledPostEndUnmutePolicy: FulfilledPostEndUnmutePolicy

    func timing(api: ProviderAPIKind, answer: Bool, start: Bool, pauseOrEnd: Bool = false) -> (
      deadline: Double, expiry: Double
    ) {
      if api == .livecommunicationkit {
        return (
          lckActionDeadlineSeconds,
          answer
            ? lckMultiCall.joinExpirySeconds
            : pauseOrEnd ? lckMultiCall.pauseEndExpirySeconds : lckActionDeadlineSeconds
        )
      }
      if answer { return (answerDeadlineSeconds, answerExpirySeconds) }
      if start { return (startDeadlineSeconds, startDeadlineSeconds) }
      return (ordinaryDeadlineSeconds, actionTimeoutSeconds)
    }

    /// Why the runtime refuses this profile for `profileID`, or `nil` when it can use it.
    func refusal(as profileID: String) -> String? {
      let durations = [
        answerExpirySeconds, ringTimeoutSeconds, unknownProviderSeconds,
        actionTimeoutSeconds, startDeadlineSeconds, answerDeadlineSeconds,
        ordinaryDeadlineSeconds, lckActionDeadlineSeconds, pushReportDeadlineSeconds,
        reportLatencySeconds, muteEchoSeconds, postEndUnmuteSeconds,
        lckMultiCall.pauseEndExpirySeconds, lckMultiCall.joinExpirySeconds,
        lckMultiCall.cleanupEndExpirySeconds, lckMultiCall.pausedAfterDeliverySeconds,
        lckMultiCall.joinedAfterSettlementSeconds, lckMultiCall.audioHandoffGapSeconds,
        lckMultiCall.audioDeactivationAfterDeliverySeconds, lckMultiCall.appResumeEndDelaySeconds,
      ]
      guard schemaVersion == 1 && id == profileID && durations.allSatisfy({ $0.isFinite && $0 > 0 })
      else {
        return "invalid behavior profile"
      }
      let filteredReasons = IncomingFilterReason.allCases.filter { $0 != .none }
      let filterPolicies = incomingFilterPolicies
      guard Set(filterPolicies.keys) == Set(filteredReasons.map(\.rawValue)),
        filteredReasons.allSatisfy({ reason in
          guard let policy = filterPolicies[reason.rawValue] else { return false }
          return policy.code == reason.code && policy.delaySeconds.isFinite
            && policy.delaySeconds > 0
            && policy.verification == (reason == .doNotDisturb ? "verified" : "unverified")
            && !policy.evidence.isEmpty
        })
      else { return "invalid incoming filter profile" }
      return nil
    }
  }

  /// An action's journal timestamps. Every effective expiry is anchored to the same integer
  /// millisecond issue time, so rounding a `Date` can't move it.
  struct ActionJournalTimes: Equatable {
    let issuedAtMS: Int64
    let deadlineMS: Int64
    let expiryMS: Int64
    init(issuedAt: Date, deadlineSeconds: Double, expirySeconds: Double) {
      issuedAtMS = Int64(issuedAt.timeIntervalSince1970 * 1000)
      deadlineMS = Int64(issuedAt.addingTimeInterval(deadlineSeconds).timeIntervalSince1970 * 1000)
      expiryMS = issuedAtMS + Int64(expirySeconds * 1000)
    }
  }

  struct RuntimeFaults: Codable {
    var staleAudio: Bool?
    var reportCallbackDelayMS: Int?
    var invalidateDuringHandoff: Bool?
    var incomingErrorCode: Int?
    mutating func apply(_ changes: [ControlRequest.FaultChange]) {
      for change in changes {
        switch change {
        case .staleAudio(let value): staleAudio = value
        case .reportCallbackDelayMS(let value): reportCallbackDelayMS = value
        case .invalidateDuringHandoff(let value): invalidateDuringHandoff = value
        case .incomingErrorCode(let value): incomingErrorCode = value
        }
      }
    }
  }
#endif
