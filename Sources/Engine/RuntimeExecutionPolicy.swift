#if os(macOS) || (os(iOS) && targetEnvironment(simulator))
  import Foundation
  #if SWIFT_PACKAGE
    import CKSimProtocol
  #endif

  /// Explicit test configuration, never inferred from a lock or an answered call.
  struct LockedAnswerScenario: Sendable {
    enum Lock: Sendable { case locked, unlocked }
    enum Activity: Sendable { case foreground, background }
    enum Coverage: Sendable { case explicitAdapters, unknownAssertions }

    let invocation: ProcessLifecycleIdentity
    let pid: Int
    let lock: Lock
    let activity: Activity
    let coverage: Coverage
  }

  /// A deterministic execution model. The caller supplies monotonic instants from its clock.
  /// Decisions neither signal a process nor claim that UIKit provided execution time.
  struct RuntimeExecutionPolicy<Instant: InstantProtocol & Sendable>: Sendable
  where Instant.Duration == Duration {
    enum Execution: Sendable { case running, suspended, exited }
    enum Eligibility: Sendable { case running, suspendEligible, unknownCoverage, exited }
    enum Source: Sendable { case pushWake, applicationAssertion, sdkPushAssertion }
    enum Allowance: Equatable, Sendable {
      case denied
      /// A scenario input, not a measured iOS allowance.
      case unverified(Duration)
    }
    enum Event: Sendable {
      case advance
      case lock(LockedAnswerScenario.Lock)
      case activity(LockedAnswerScenario.Activity)
      case coverage(LockedAnswerScenario.Coverage)
      case execution(Execution)
      case begin(UUID, Source, Allowance)
      case end(UUID)
      case expire(UUID)
      case audio(UUID, activated: Bool, mediaActive: Bool, backgroundCapable: Bool)
    }
    enum Failure: Error, Equatable {
      case invalidPID, staleIdentity, backwardsTime, invalidDuration, reusedID, unknownID
      case processExited
    }
    enum Lifetime: Equatable, Sendable { case active, denied, ended, expired }
    struct Assertion: Equatable, Sendable {
      let id: UUID
      let source: Source
      let allowance: Allowance
      let due: Instant?
      var lifetime: Lifetime
    }
    struct Audio: Equatable, Sendable {
      let id: UUID
      let activated: Bool
      let mediaActive: Bool
      let backgroundCapable: Bool
      var supportsExecution: Bool { activated && mediaActive && backgroundCapable }
    }
    struct Decision: Equatable, Sendable {
      let eligibility: Eligibility
      let execution: Execution
      let lock: LockedAnswerScenario.Lock
      let activity: LockedAnswerScenario.Activity
      let coverage: LockedAnswerScenario.Coverage
      /// All active bounded reasons, including their identity, source and unverified due time.
      let assertions: [Assertion]
      let audio: Audio?
      let nextDeadline: Instant?
    }

    private let invocation: ProcessLifecycleIdentity
    private let pid: Int
    private var lock: LockedAnswerScenario.Lock
    private var activity: LockedAnswerScenario.Activity
    private var coverage: LockedAnswerScenario.Coverage
    private var execution = Execution.running
    private var observedAt: Instant
    private var assertions: [UUID: Assertion] = [:]
    private var audio: Audio?

    init(scenario: LockedAnswerScenario, at now: Instant) throws(Failure) {
      guard scenario.pid > 0 else { throw .invalidPID }
      invocation = scenario.invocation
      pid = scenario.pid
      lock = scenario.lock
      activity = scenario.activity
      coverage = scenario.coverage
      observedAt = now
    }

    /// Invalid or stale inputs leave every state and deadline unchanged.
    mutating func reduce(
      _ event: Event, invocation: ProcessLifecycleIdentity, pid: Int, at now: Instant
    ) throws(Failure) -> Decision {
      guard invocation == self.invocation, pid == self.pid else { throw .staleIdentity }
      guard now >= observedAt else { throw .backwardsTime }
      guard execution != .exited else { throw .processExited }
      var next = self
      try next.apply(event, at: now)
      self = next
      return decision
    }

    var decision: Decision {
      let active = assertions.values.filter { $0.lifetime == .active }
        .sorted { $0.id.uuidString < $1.id.uuidString }
      let eligibility: Eligibility
      if execution == .exited {
        eligibility = .exited
      } else if coverage == .unknownAssertions {
        // Unknown third-party assertions prevent an execution-conformance decision.
        eligibility = .unknownCoverage
      } else if activity == .foreground || !active.isEmpty || audio?.supportsExecution == true {
        eligibility = .running
      } else {
        eligibility = .suspendEligible
      }
      return Decision(
        eligibility: eligibility, execution: execution, lock: lock, activity: activity,
        coverage: coverage, assertions: active, audio: audio,
        nextDeadline: active.compactMap(\.due).min())
    }

    func lifetime(of id: UUID) -> Lifetime? { assertions[id]?.lifetime }

    private mutating func apply(_ event: Event, at now: Instant) throws(Failure) {
      observedAt = now
      for (id, assertion) in assertions where assertion.lifetime == .active {
        if let due = assertion.due, due <= now { assertions[id]?.lifetime = .expired }
      }
      switch event {
      case .advance: break
      case .lock(let value): lock = value
      case .activity(let value): activity = value
      case .coverage(let value): coverage = value
      case .execution(let value):
        execution = value
        if value == .exited {
          for id in assertions.keys where assertions[id]?.lifetime == .active {
            assertions[id]?.lifetime = .ended
          }
          audio = nil
        }
      case .begin(let id, let source, let allowance):
        guard assertions[id] == nil, audio?.id != id else { throw .reusedID }
        let due: Instant?
        let lifetime: Lifetime
        switch allowance {
        case .denied:
          due = nil
          lifetime = .denied
        case .unverified(let duration):
          guard duration > .zero else { throw .invalidDuration }
          due = now.advanced(by: duration)
          lifetime = .active
        }
        assertions[id] = Assertion(
          id: id, source: source, allowance: allowance, due: due, lifetime: lifetime)
      case .end(let id):
        guard let assertion = assertions[id] else { throw .unknownID }
        if assertion.lifetime == .active { assertions[id]?.lifetime = .ended }
      case .expire(let id):
        guard let assertion = assertions[id] else { throw .unknownID }
        if assertion.lifetime == .active { assertions[id]?.lifetime = .expired }
      case .audio(let id, let activated, let mediaActive, let backgroundCapable):
        guard assertions[id] == nil, audio == nil || audio?.id == id else { throw .reusedID }
        audio = Audio(
          id: id, activated: activated, mediaActive: mediaActive,
          backgroundCapable: backgroundCapable)
      }
    }
  }
#endif
