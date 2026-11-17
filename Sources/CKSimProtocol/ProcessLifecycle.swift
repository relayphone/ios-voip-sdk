public import Foundation

/// A simulator application invocation, including the time before its process exists.
public struct ProcessLifecycleIdentity: Codable, Equatable, Sendable {
  /// The simulator containing the application.
  public let simulatorID: UUID
  /// The application that owns the invocation.
  public let bundleID: String
  /// The invocation shared by host and runtime journal segments.
  public let runID: String

  /// Creates an identity that can safely name a journal directory.
  public init(simulatorID: UUID, bundleID: String, runID: String) throws(RuntimeIdentity
    .ValidationError)
  {
    guard validRuntimeRunID(runID) else { throw .invalidRunID }
    guard !bundleID.isEmpty else { throw .emptyBundleID }
    self.simulatorID = simulatorID
    self.bundleID = bundleID
    self.runID = runID
  }

  private enum CodingKeys: String, CodingKey { case simulatorID, bundleID, runID }

  /// Validates identities read from a journal.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      simulatorID: values.decode(UUID.self, forKey: .simulatorID),
      bundleID: values.decode(String.self, forKey: .bundleID),
      runID: values.decode(String.self, forKey: .runID))
  }
}

/// An observed process boundary or terminal delivery outcome; readiness is never inferred.
public struct ProcessLifecycleEvent: RawRepresentable, Codable, Equatable, Hashable, Sendable {
  /// The additive journal event name, including names from newer producers.
  public let rawValue: String
  /// Preserves known and future version-one event names.
  public init(rawValue: String) { self.rawValue = rawValue }
  /// Decodes an event name without rejecting a newer producer's observation.
  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }
  /// Writes the existing journal event string.
  public func encode(to encoder: any Encoder) throws {
    var value = encoder.singleValueContainer()
    try value.encode(rawValue)
  }
  /// The host durably retains an individual cold-launch delivery before starting the app.
  public static let launchScheduled = Self(rawValue: "push.launchScheduled")
  /// The host is about to request simulator launch.
  public static let launchRequested = Self(rawValue: "process.launchRequested")
  /// The host durably recorded termination intent before verifying and stopping the process.
  public static let killRequested = Self(rawValue: "process.killRequested")
  /// The host retained a bounded suspension intent before SIGSTOP.
  public static let suspendRequested = Self(rawValue: "process.suspendRequested")
  /// The host observed the pinned process in the kernel's stopped state.
  public static let suspended = Self(rawValue: "process.suspended")
  /// The host observed the pinned process running again after SIGCONT.
  public static let resumed = Self(rawValue: "process.resumed")
  /// Recovery failed; no successful resume may be inferred.
  public static let suspensionCleanupFailed = Self(rawValue: "process.suspensionCleanupFailed")
  /// The application's earliest instrumented entry point executed.
  public static let entered = Self(rawValue: "process.entered")
  /// Runtime hooks and the mailbox are available.
  public static let runtimeReady = Self(rawValue: "runtime.ready")
  /// A registry has a delegate and VoIP types on its delivery queue.
  public static let registryReady = Self(rawValue: "push.registryReady")
  /// Native acknowledgement of an attached application handler.
  public static let handlerReady = Self(rawValue: "app.handlerReady")
  /// Actual PushKit delegate entry for a delivery.
  public static let delivered = Self(rawValue: "push.delivered")
  /// The host confirmed process exit.
  public static let exited = Self(rawValue: "process.exited")
  /// The host could not launch the application.
  public static let launchFailed = Self(rawValue: "process.launchFailed")
  /// Observation ended without registry readiness.
  public static let registryMissing = Self(rawValue: "push.registryMissing")
  /// A staged envelope exceeded its freshness window.
  public static let envelopeExpired = Self(rawValue: "push.envelopeExpired")
  /// Observation ended without handler acknowledgement.
  public static let handlerMissing = Self(rawValue: "app.handlerMissing")
  /// The request was dropped without launching or delivering.
  public static let dropped = Self(rawValue: "push.dropped")
  /// Process exit cancelled an undelivered copy.
  public static let cancelled = Self(rawValue: "push.cancelled")
}

/// Test intent for process termination; it does not establish OS launch eligibility.
public enum ProcessExitCause: String, Codable, Sendable {
  /// Abrupt loss of application memory without cleanup.
  case abrupt
  /// Simulator termination requested by the test.
  case userRequested = "user-requested"
  /// No requested cause is established.
  case unknown
}

/// A version-one journal row owned by one host producer, correlated by invocation.
public struct ProcessLifecycleRecord: Codable, Equatable, Sendable {
  /// Supported journal wire version.
  public let schemaVersion: Int
  /// The sole writer of this segment.
  public let producerID: UUID
  /// Contiguous sequence local to this producer, starting at one.
  public let sequence: UInt64
  /// Simulator containing the invocation.
  public let simulatorID: UUID
  /// Application owning the invocation.
  public let bundleID: String
  /// Invocation shared with runtime rows.
  public let runID: String
  /// Observed app process, absent before a process exists.
  public let pid: Int?
  /// Boundary or terminal outcome observed by the producer.
  public let event: ProcessLifecycleEvent
  /// Absolute monotonic uptime, shared by host and simulator on the same Mac.
  public let uptimeNanoseconds: UInt64
  /// Wall-clock time for display only; never used to order events.
  public let wallTimeMS: Int64
  /// Correlated host control or push request, when present.
  public let requestID: UUID?
  /// Correlated individual delivery, when present.
  public let pushID: UUID?
  /// Requested termination intent, when established.
  public let cause: ProcessExitCause?

  /// An invalid version, sequence, time or app process in a journal row.
  public enum ValidationError: Error, Equatable, Sendable { case invalidRecord }

  /// Creates a validated journal row without inventing a prelaunch PID.
  public init(
    identity: ProcessLifecycleIdentity, producerID: UUID, sequence: UInt64,
    pid: Int? = nil, event: ProcessLifecycleEvent, uptimeNanoseconds: UInt64,
    wallTimeMS: Int64, requestID: UUID? = nil, pushID: UUID? = nil,
    cause: ProcessExitCause? = nil
  ) throws(ValidationError) {
    guard sequence > 0, uptimeNanoseconds > 0, wallTimeMS >= 0, !event.rawValue.isEmpty,
      pid.map({ $0 > 0 }) ?? true
    else { throw ValidationError.invalidRecord }
    schemaVersion = 1
    self.producerID = producerID
    self.sequence = sequence
    simulatorID = identity.simulatorID
    bundleID = identity.bundleID
    runID = identity.runID
    self.pid = pid
    self.event = event
    self.uptimeNanoseconds = uptimeNanoseconds
    self.wallTimeMS = wallTimeMS
    self.requestID = requestID
    self.pushID = pushID
    self.cause = cause
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, producerID, sequence, simulatorID, bundleID, runID, pid, event,
      uptimeNanoseconds, wallTimeMS, requestID, pushID, cause
  }

  /// Decodes and validates each row independently of its segment reader.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    guard try values.decode(Int.self, forKey: .schemaVersion) == 1 else {
      throw ValidationError.invalidRecord
    }
    try self.init(
      identity: ProcessLifecycleIdentity(
        simulatorID: values.decode(UUID.self, forKey: .simulatorID),
        bundleID: values.decode(String.self, forKey: .bundleID),
        runID: values.decode(String.self, forKey: .runID)),
      producerID: values.decode(UUID.self, forKey: .producerID),
      sequence: values.decode(UInt64.self, forKey: .sequence),
      pid: values.decodeIfPresent(Int.self, forKey: .pid),
      event: values.decode(ProcessLifecycleEvent.self, forKey: .event),
      uptimeNanoseconds: values.decode(UInt64.self, forKey: .uptimeNanoseconds),
      wallTimeMS: values.decode(Int64.self, forKey: .wallTimeMS),
      requestID: values.decodeIfPresent(UUID.self, forKey: .requestID),
      pushID: values.decodeIfPresent(UUID.self, forKey: .pushID),
      cause: values.decodeIfPresent(ProcessExitCause.self, forKey: .cause))
  }
}

/// Invocation-local readiness evidence. Launch-relative durations include simulator service latency.
public struct ProcessReadinessSnapshot: Codable, Equatable, Sendable {
  /// Native sources accepted as readiness evidence.
  public enum Source: String, Codable, Sendable {
    /// Registry checked on the queue used for delegate delivery.
    case registryQueue = "registry-delivery-queue"
    /// Explicit native acknowledgement of an installed handler generation.
    case handlerAttachment = "native-handler-acknowledgement"
  }
  /// A runtime boundary with explicit native provenance and optional handler generation.
  public struct Observation: Codable, Equatable, Sendable {
    /// Absolute monotonic observation time.
    public let uptimeNanoseconds: UInt64
    /// Native observation source, never inferred from another boundary.
    public let source: Source
    /// Acknowledged handler generation; absent for registry readiness.
    public let generation: Int?
    /// Creates a native observation.
    public init(uptimeNanoseconds: UInt64, source: Source, generation: Int? = nil) {
      self.uptimeNanoseconds = uptimeNanoseconds
      self.source = source
      self.generation = generation
    }
  }
  /// Host launch intent time; absent for invocations launched by another driver.
  public var launchRequested: UInt64?
  /// First instrumented Swift preparation entry, excluding earlier startup/dyld work.
  public var entered: UInt64?
  /// Completed runtime hook installation.
  public var runtimeReady: UInt64?
  /// First registry ready on its delivery queue.
  public var registry: Observation?
  /// Latest explicitly acknowledged handler generation.
  public var handler: Observation?
  /// Host observation deadline passed without registry readiness.
  public var registryTimedOut = false
  /// Host observation deadline passed without handler readiness.
  public var handlerTimedOut = false
  /// Creates an empty projection; missing observations are never zero-filled.
  public init() {}
  private enum CodingKeys: String, CodingKey {
    case launchRequested, entered, runtimeReady, registry, handler, registryTimedOut,
      handlerTimedOut
    case launchToRegistryMS, launchToHandlerMS, entryToRegistryMS, entryToHandlerMS
    case runtimeToRegistryMS, runtimeToHandlerMS
  }
  /// Encodes optional measured durations without substituting a zero for absent evidence.
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encodeIfPresent(launchRequested, forKey: .launchRequested)
    try values.encodeIfPresent(entered, forKey: .entered)
    try values.encodeIfPresent(runtimeReady, forKey: .runtimeReady)
    try values.encodeIfPresent(registry, forKey: .registry)
    try values.encodeIfPresent(handler, forKey: .handler)
    try values.encode(registryTimedOut, forKey: .registryTimedOut)
    try values.encode(handlerTimedOut, forKey: .handlerTimedOut)
    for (anchor, observation, key) in [
      (launchRequested, registry, CodingKeys.launchToRegistryMS),
      (launchRequested, handler, .launchToHandlerMS),
      (entered, registry, .entryToRegistryMS), (entered, handler, .entryToHandlerMS),
      (runtimeReady, registry, .runtimeToRegistryMS), (runtimeReady, handler, .runtimeToHandlerMS),
    ] {
      if let anchor, let observation, observation.uptimeNanoseconds >= anchor {
        try values.encode(Double(observation.uptimeNanoseconds - anchor) / 1_000_000, forKey: key)
      }
    }
  }
  /// Decodes observations from an additive status projection.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    launchRequested = try values.decodeIfPresent(UInt64.self, forKey: .launchRequested)
    entered = try values.decodeIfPresent(UInt64.self, forKey: .entered)
    runtimeReady = try values.decodeIfPresent(UInt64.self, forKey: .runtimeReady)
    registry = try values.decodeIfPresent(Observation.self, forKey: .registry)
    handler = try values.decodeIfPresent(Observation.self, forKey: .handler)
    registryTimedOut = try values.decode(Bool.self, forKey: .registryTimedOut)
    handlerTimedOut = try values.decode(Bool.self, forKey: .handlerTimedOut)
  }
}
