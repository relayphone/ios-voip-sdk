import Foundation

/// The framework whose provider is represented by a runtime snapshot.
public enum ProviderAPI: String, Codable, Sendable {
  /// A CallKit provider.
  case callkit
  /// A LiveCommunicationKit provider using the simulator's CallKit adapter.
  case livecommunicationkit
}

/// The configured incoming-report filter and its advertised verification.
public struct IncomingFilterSnapshot: Codable, Equatable, Sendable {
  /// The configured filter policy.
  public let reason: ControlRequest.FilterReason
  /// The corresponding incoming-call error code, or zero when disabled.
  public let code: Int
  /// The profile's verification classification.
  public let verification: String

  /// Creates a filter state whose reason, code and verification agree.
  public init(reason: ControlRequest.FilterReason, code: Int, verification: String) throws {
    let expectedCode: Int
    switch reason {
    case .none: expectedCode = 0
    case .doNotDisturb: expectedCode = 3
    case .restrictedSharingMode: expectedCode = 5
    case .callIsProtected: expectedCode = 6
    case .sensitiveParticipants: expectedCode = 7
    }
    let expectedVerification =
      reason == .none ? "not-applicable" : reason == .doNotDisturb ? "verified" : "unverified"
    guard code == expectedCode, verification == expectedVerification else {
      throw invalidControlValue([], "Inconsistent incoming filter state.")
    }
    self.reason = reason
    self.code = code
    self.verification = verification
  }
  private enum CodingKeys: String, CodingKey { case reason, code, verification }
  /// Decodes a complete filter state, rejecting inconsistent policy metadata.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      reason: values.decode(ControlRequest.FilterReason.self, forKey: .reason),
      code: values.decode(Int.self, forKey: .code),
      verification: values.decode(String.self, forKey: .verification))
  }
}

/// A call's common state together with framework-specific grouping information.
public struct CallSnapshot: Codable, Equatable, Sendable {
  /// Framework-independent identity, state and presentation fields.
  public let state: State
  /// CallKit group identity or authoritative LCK system choices.
  public let relationship: Relationship

  /// The state fields common to both supported provider frameworks.
  public struct State: Codable, Equatable, Sendable {
    /// The call identity.
    public let uuid: UUID
    /// Whether the call originated locally.
    public let outgoing: Bool
    /// Whether the call connected.
    public let connected: Bool
    /// Whether the call is held.
    public let held: Bool
    /// Whether the call ended.
    public let ended: Bool
    /// Whether the call is muted.
    public let muted: Bool
    /// Whether an incoming call is still ringing.
    public let ringing: Bool
    /// The caller's display name, empty when absent.
    public let callerName: String
    /// The remote handle, empty when absent.
    public let handle: String
    /// The operations advertised by the incoming call update.
    public let capabilities: [Capability]

    /// An advertised call capability.
    public enum Capability: String, Codable, Sendable {
      /// Pause or resume the conversation.
      case pausing
      /// Merge the conversation into a group.
      case merging
      /// Remove the conversation from a group.
      case unmerging
    }
    /// Creates the common state without imposing additional lifecycle transitions.
    public init(
      uuid: UUID, outgoing: Bool, connected: Bool, held: Bool, ended: Bool,
      muted: Bool, ringing: Bool, callerName: String, handle: String, capabilities: [Capability]
    ) {
      self.uuid = uuid
      self.outgoing = outgoing
      self.connected = connected
      self.held = held
      self.ended = ended
      self.muted = muted
      self.ringing = ringing
      self.callerName = callerName
      self.handle = handle
      self.capabilities = capabilities
    }
  }
  /// A system-provided choice for an incoming LCK conversation.
  public enum SystemChoice: String, Codable, Sendable {
    /// Accept the incoming conversation.
    case answer
    /// Decline the incoming conversation.
    case decline
    /// Hold the active conversation and accept the incoming one.
    case holdAndAccept = "hold-and-accept"
    /// End the active conversation and accept the incoming one.
    case endAndAccept = "end-and-accept"
    /// End the held conversation and accept the incoming one.
    case endHeldAndAccept = "end-held-and-accept"
  }
  /// The framework-specific information that must accompany a call snapshot.
  public enum Relationship: Equatable, Sendable {
    /// CallKit exposes an actual group identity.
    case callkit(group: UUID)
    /// LCK exposes system choices instead of a group identity.
    case livecommunicationkit(availableSystemChoices: [SystemChoice])
  }
  /// Creates a snapshot with exactly one framework-specific relationship.
  public init(state: State, relationship: Relationship) {
    self.state = state
    self.relationship = relationship
  }
  private enum CodingKeys: String, CodingKey { case apiKind, group, availableSystemChoices }
  /// Decodes the existing flat call fields and the selected framework's relationship.
  public init(from decoder: any Decoder) throws {
    state = try State(from: decoder)
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(ProviderAPI.self, forKey: .apiKind) {
    case .callkit:
      guard !values.contains(.availableSystemChoices) else {
        throw invalidControlValue(decoder.codingPath, "CallKit call has LCK choices.")
      }
      relationship = .callkit(group: try values.decode(UUID.self, forKey: .group))
    case .livecommunicationkit:
      guard !values.contains(.group) else {
        throw invalidControlValue(decoder.codingPath, "LCK call has a CallKit group.")
      }
      relationship = .livecommunicationkit(
        availableSystemChoices: try values.decode(
          [SystemChoice].self, forKey: .availableSystemChoices))
    }
  }
  /// Writes the existing flat call shape, without introducing a nested state object.
  public func encode(to encoder: any Encoder) throws {
    try state.encode(to: encoder)
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch relationship {
    case .callkit(let group):
      try values.encode(ProviderAPI.callkit, forKey: .apiKind)
      try values.encode(group, forKey: .group)
    case .livecommunicationkit(let choices):
      try values.encode(ProviderAPI.livecommunicationkit, forKey: .apiKind)
      try values.encode(choices, forKey: .availableSystemChoices)
    }
  }
}

/// The configuration and ownership state of one registered provider.
public struct ProviderSnapshot: Codable, Equatable, Sendable {
  /// An opaque textual provider identity, not a UUID.
  public let provider: String
  /// The provider's framework.
  public let apiKind: ProviderAPI
  /// Whether runtime controls currently target this provider.
  public let selected: Bool
  /// Whether the provider remains valid.
  public let valid: Bool
  /// The configured maximum number of call groups.
  public let maximumCallGroups: Int
  /// The configured maximum number of calls per group.
  public let maximumCallsPerCallGroup: Int

  /// Creates a snapshot without changing provider-selection or limit policy.
  public init(
    provider: String, apiKind: ProviderAPI, selected: Bool, valid: Bool,
    maximumCallGroups: Int, maximumCallsPerCallGroup: Int
  ) {
    self.provider = provider
    self.apiKind = apiKind
    self.selected = selected
    self.valid = valid
    self.maximumCallGroups = maximumCallGroups
    self.maximumCallsPerCallGroup = maximumCallsPerCallGroup
  }
}

/// The complete status result from one runtime invocation.
public struct RuntimeSnapshot: Codable, Equatable, Sendable {
  /// Current calls, in the runtime's existing snapshot order.
  public let calls: [CallSnapshot]
  /// The number of unsettled runtime actions.
  public let pending: UInt
  /// Whether runtime-managed audio is active.
  public let audioActive: Bool
  /// The last successfully written journal sequence.
  public let sequence: UInt64
  /// The configured incoming-report fault code, or zero when disabled.
  public let incomingErrorCode: Int
  /// The configured incoming filter.
  public let incomingFilter: IncomingFilterSnapshot
  /// Registered providers in the runtime's existing identity order.
  public let providerConfigurations: [ProviderSnapshot]

  /// Creates a status value without changing runtime state or journal sequence.
  public init(
    calls: [CallSnapshot], pending: UInt, audioActive: Bool, sequence: UInt64,
    incomingErrorCode: Int, incomingFilter: IncomingFilterSnapshot,
    providerConfigurations: [ProviderSnapshot]
  ) {
    self.calls = calls
    self.pending = pending
    self.audioActive = audioActive
    self.sequence = sequence
    self.incomingErrorCode = incomingErrorCode
    self.incomingFilter = incomingFilter
    self.providerConfigurations = providerConfigurations
  }
}

func invalidControlValue(_ path: [any CodingKey], _ message: String) -> DecodingError {
  .dataCorrupted(.init(codingPath: path, debugDescription: message))
}
