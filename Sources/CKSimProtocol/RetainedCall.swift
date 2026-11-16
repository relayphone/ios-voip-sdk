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
  /// Video state confirmed by a framework report, never an unfulfilled request.
  public var hasVideo = false
  /// Confirmed video transitions on this call's monotonic timeline.
  public var videoChanges: [VideoChange] = []
  /// One confirmed video transition, in milliseconds from the runtime epoch.
  public struct VideoChange: Codable, Equatable, Sendable {
    /// Milliseconds since this runtime invocation began.
    public let atMS: UInt64
    /// The video state confirmed at this observation.
    public let hasVideo: Bool
    /// Creates a confirmed observation.
    public init(atMS: UInt64, hasVideo: Bool) {
      self.atMS = atMS
      self.hasVideo = hasVideo
    }
  }
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

// Older runtime journals omit video observations.
extension RetainedCall {
  private enum CodingKeys: String, CodingKey {
    case uuid, callID, state, hasVideo, videoChanges, endReason, reportedAtMS, answeredAtMS,
      connectedAtMS, endedAtMS
  }
  /// Decodes current observations and recordings that predate video fields.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    uuid = try values.decode(UUID.self, forKey: .uuid)
    callID = try values.decodeIfPresent(String.self, forKey: .callID)
    state = try values.decode(Phase.self, forKey: .state)
    hasVideo = try values.decodeIfPresent(Bool.self, forKey: .hasVideo) ?? false
    videoChanges = try values.decodeIfPresent([VideoChange].self, forKey: .videoChanges) ?? []
    endReason = try values.decodeIfPresent(String.self, forKey: .endReason)
    reportedAtMS = try values.decodeIfPresent(UInt64.self, forKey: .reportedAtMS)
    answeredAtMS = try values.decodeIfPresent(UInt64.self, forKey: .answeredAtMS)
    connectedAtMS = try values.decodeIfPresent(UInt64.self, forKey: .connectedAtMS)
    endedAtMS = try values.decodeIfPresent(UInt64.self, forKey: .endedAtMS)
  }
}
