public import Foundation

/// A call retained for host diagnostics, with times in milliseconds from the runtime epoch.
public struct RetainedCall: Codable, Equatable, Sendable {
  /// System UUID, also available before the SDK associates its server call ID.
  public let uuid: UUID
  /// The SDK's call ID; absent for apps that use the calling frameworks directly.
  public var callID: String?
  /// The observed lifecycle phase.
  public enum Phase: String, Codable, Sendable {
    case ringing, dialing, previewing, connecting, connected, reconnecting, ended
  }
  public var state: Phase
  /// SDK end reason when known; otherwise the runtime's system end reason.
  public var endReason: String?
  /// First framework report; absent for SDK previews that never reach the system.
  public var reportedAtMS: UInt64?
  /// First answer delivery on this device.
  public var answeredAtMS: UInt64?
  /// First observed connection, independent of system answer fulfillment.
  public var connectedAtMS: UInt64?
  /// End observation on the shared monotonic timeline.
  public var endedAtMS: UInt64?

  /// Starts a diagnostic record at the call's first observation.
  public init(uuid: UUID, state: Phase, reportedAtMS: UInt64?) {
    self.uuid = uuid
    self.state = state
    self.reportedAtMS = reportedAtMS
  }
}
