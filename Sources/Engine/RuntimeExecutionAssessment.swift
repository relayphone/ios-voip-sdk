#if os(macOS) || (os(iOS) && targetEnvironment(simulator))
  import Foundation
  #if SWIFT_PACKAGE
    import CKSimProtocol
  #endif

  /// Replays explicit adapter evidence through the execution reducer on an injected clock.
  /// Snapshot timestamps anchor allowances; polling latency never extends their due times.
  struct RuntimeExecutionAssessment<Instant: InstantProtocol & Sendable>: Sendable
  where Instant.Duration == Duration {
    typealias Policy = RuntimeExecutionPolicy<Instant>
    struct Allowances: Sendable {
      let applicationAssertion: Duration
      let sdkPushAssertion: Duration
    }
    struct Audio: Sendable {
      let id: UUID
      let activated: Bool
      let mediaActive: Bool
      let backgroundCapable: Bool
    }
    struct State: Sendable {
      let lock: LockedAnswerScenario.Lock
      let activity: LockedAnswerScenario.Activity
      let execution: Policy.Execution
      var audio: Audio? = nil
    }
    struct Wake: Sendable {
      let id: UUID
      let beganAt: UInt64
      let endedAt: UInt64?
      let unverifiedAllowance: Duration
    }
    enum Failure: Error, Equatable {
      case invalidAllowance, staleIdentity, invalidTime, regressedHistory, processExited
      case policy(Policy.Failure)
    }
    private struct Boundary {
      let time: UInt64
      let order: Int
      let id: UUID
      let event: Policy.Event
    }

    private let scenario: LockedAnswerScenario
    private let allowances: Allowances
    private let origin: Instant
    private let epoch: UInt64
    private var previous: [UUID: BackgroundAssertionSnapshot] = [:]
    private var lastUptime: UInt64
    private var unknown = false
    private var previousWake: Wake?
    private var exited = false

    init(scenario: LockedAnswerScenario, allowances: Allowances, epoch: UInt64, at origin: Instant)
      throws(Failure)
    {
      guard allowances.applicationAssertion > .zero, allowances.sdkPushAssertion > .zero else {
        throw .invalidAllowance
      }
      guard epoch > 0, scenario.pid > 0 else { throw .invalidTime }
      self.scenario = scenario
      self.allowances = allowances
      self.epoch = epoch
      self.origin = origin
      lastUptime = epoch
    }

    /// Input identity comes from the verified invocation, not from an assertion identifier.
    /// Missing/incomplete evidence makes coverage unknown, including on later assessments.
    mutating func assess(
      _ snapshot: BackgroundAssertionsSnapshot?, invocation: ProcessLifecycleIdentity, pid: Int,
      state: State, wake: Wake? = nil, uptime: UInt64
    ) throws(Failure) -> Policy.Decision {
      guard invocation == scenario.invocation, pid == scenario.pid else {
        throw Failure.staleIdentity
      }
      guard uptime >= lastUptime, uptime - epoch <= UInt64(Int64.max) else {
        throw Failure.invalidTime
      }
      guard !exited else { throw Failure.processExited }
      let rows = snapshot?.assertions ?? []
      var current: [UUID: BackgroundAssertionSnapshot] = [:]
      var boundaries: [Boundary] = []
      var incomplete = unknown || snapshot == nil || snapshot?.hasUnresolvedObservations == true
      func valid(_ time: UInt64) -> Bool { time >= epoch && time <= uptime }
      func append(_ time: UInt64, _ order: Int, _ id: UUID, _ event: Policy.Event) {
        boundaries.append(Boundary(time: time, order: order, id: id, event: event))
      }
      for row in rows {
        guard current[row.id] == nil, valid(row.requestedAt),
          [row.beganAt, row.deniedAt, row.expiredAt, row.endedAt].compactMap({ $0 })
            .allSatisfy({ valid($0) && $0 >= row.requestedAt }),
          !(row.beganAt != nil && row.deniedAt != nil),
          (row.endedAt == nil) == (row.endCount == 0),
          row.endedAt.map({ end in row.beganAt.map({ $0 <= end }) ?? false }) ?? true,
          row.deniedAt.map({ denied in row.expiredAt.map({ $0 <= denied }) ?? true }) ?? true
        else {
          incomplete = true
          continue
        }
        current[row.id] = row
        let source: Policy.Source
        let allowance: Duration
        switch row.source {
        case .applicationAssertion:
          source = .applicationAssertion
          allowance = allowances.applicationAssertion
        case .sdkPushAssertion:
          source = .sdkPushAssertion
          allowance = allowances.sdkPushAssertion
        }
        if let began = row.beganAt {
          append(began, 0, row.id, .begin(row.id, source, .unverified(allowance)))
          if let expired = row.expiredAt {
            // Expiration may precede the return: apply it immediately after begin in replay.
            append(max(began, expired), 1, row.id, .expire(row.id))
          }
          if let ended = row.endedAt { append(ended, 2, row.id, .end(row.id)) }
        } else if let denied = row.deniedAt {
          append(denied, 0, row.id, .begin(row.id, source, .denied))
        } else {
          // A request still inside begin cannot establish adapter coverage.
          incomplete = true
        }
      }
      for (id, old) in previous {
        guard let row = current[id], row.source == old.source, row.requestedAt == old.requestedAt,
          old.beganAt == nil || row.beganAt == old.beganAt,
          old.deniedAt == nil || row.deniedAt == old.deniedAt,
          old.expiredAt == nil || row.expiredAt == old.expiredAt,
          old.endedAt == nil || row.endedAt == old.endedAt, row.endCount >= old.endCount
        else { throw Failure.regressedHistory }
      }
      if let old = previousWake {
        guard let wake, wake.id == old.id, wake.beganAt == old.beganAt,
          wake.unverifiedAllowance == old.unverifiedAllowance,
          old.endedAt == nil || wake.endedAt == old.endedAt
        else { throw Failure.regressedHistory }
      }
      if let wake {
        guard current[wake.id] == nil, valid(wake.beganAt), wake.unverifiedAllowance > .zero,
          wake.endedAt.map({ valid($0) && $0 >= wake.beganAt }) ?? true
        else { throw Failure.invalidTime }
        append(
          wake.beganAt, 0, wake.id,
          .begin(wake.id, .pushWake, .unverified(wake.unverifiedAllowance)))
        if let end = wake.endedAt { append(end, 2, wake.id, .end(wake.id)) }
      }
      do {
        var policy = try Policy(scenario: scenario, at: origin)
        for boundary in boundaries.sorted(by: {
          if $0.time != $1.time { return $0.time < $1.time }
          if $0.order != $1.order { return $0.order < $1.order }
          return $0.id.uuidString < $1.id.uuidString
        }) {
          _ = try policy.reduce(
            boundary.event, invocation: invocation, pid: pid,
            at: origin.advanced(by: .nanoseconds(Int64(boundary.time - epoch))))
        }
        let now = origin.advanced(by: .nanoseconds(Int64(uptime - epoch)))
        for event in [Policy.Event.lock(state.lock), .activity(state.activity)] {
          _ = try policy.reduce(event, invocation: invocation, pid: pid, at: now)
        }
        if let audio = state.audio {
          _ = try policy.reduce(
            .audio(
              audio.id, activated: audio.activated, mediaActive: audio.mediaActive,
              backgroundCapable: audio.backgroundCapable), invocation: invocation, pid: pid, at: now
          )
        }
        if incomplete {
          _ = try policy.reduce(
            .coverage(.unknownAssertions), invocation: invocation, pid: pid, at: now)
        }
        let decision = try policy.reduce(
          .execution(state.execution), invocation: invocation, pid: pid, at: now)
        previous = current
        previousWake = wake
        exited = state.execution == .exited
        lastUptime = uptime
        // Pending begin is transient; absent or corrupt histories remain unknown permanently.
        unknown =
          unknown || snapshot == nil || snapshot?.hasUnresolvedObservations == true
          || current.count != rows.count
        return decision
      } catch { throw .policy(error) }
    }
  }
#endif
