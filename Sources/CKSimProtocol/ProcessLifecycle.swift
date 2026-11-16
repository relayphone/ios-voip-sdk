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
  /// The host is about to request simulator launch.
  public static let launchRequested = Self(rawValue: "process.launchRequested")
  /// The host durably recorded termination intent before verifying and stopping the process.
  public static let killRequested = Self(rawValue: "process.killRequested")
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
  /// Correlated push request, when present.
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
