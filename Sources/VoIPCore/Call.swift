public import Foundation

/// A real-time voice or video interaction as this device knows it: ringing here, taking part
/// here, or followed in a call preview while it continues elsewhere.
///
/// LiveCommunicationKit calls this a conversation. The SDK keeps its own state for every call,
/// keyed by ``CallID``; the calling framework only presents it.
public struct Call: Identifiable, Hashable, Sendable {
  /// The app's identifier for the call, the same on every device that rings for it.
  public let id: CallID

  /// Whether the call arrived at this device, rather than being started here.
  public let isIncoming: Bool

  /// The parties on the other side of the call. The system presents the first.
  public var parties: [Party]

  /// Where the call is in its life on this device.
  public var status: CallStatus

  /// Whether this device's microphone is muted for the call.
  public var isMuted: Bool

  /// Whether the call is on hold, so that neither side hears the other.
  public var isOnHold: Bool

  /// Whether the call includes video.
  public var hasVideo: Bool

  /// When the user answered the call on this device, if they did.
  public var answeredAt: Date?

  /// When the call first connected on this device, if it did.
  public var connectedAt: Date?

  /// Values the app attached to the call, which the SDK passes through unchanged.
  ///
  /// For an incoming call, it is the ``IncomingCall/metadata`` from its VoIP push or from
  /// ``VoIPClient/report(_:)``; for an outgoing call, the ``OutgoingCall/metadata`` it started
  /// with. Read a value by matching its case:
  ///
  /// ```swift
  /// if case .string(let room)? = call.metadata["room"] {
  ///   try await server.join(room: room)
  /// }
  /// ```
  public var metadata: [String: JSONValue]

  /// Creates a call.
  ///
  /// - Parameters:
  ///   - id: The app's identifier for the call.
  ///   - isIncoming: Whether the call arrived at this device.
  ///   - parties: The parties on the other side of the call.
  ///   - status: Where the call is in its life on this device.
  ///   - isMuted: Whether this device's microphone is muted for the call.
  ///   - isOnHold: Whether the call is on hold.
  ///   - hasVideo: Whether the call includes video.
  ///   - answeredAt: When the user answered the call on this device.
  ///   - connectedAt: When the call first connected on this device.
  ///   - metadata: Values the app attached to the call.
  public init(
    id: CallID,
    isIncoming: Bool,
    parties: [Party],
    status: CallStatus,
    isMuted: Bool = false,
    isOnHold: Bool = false,
    hasVideo: Bool = false,
    answeredAt: Date? = nil,
    connectedAt: Date? = nil,
    metadata: [String: JSONValue] = [:]
  ) {
    self.id = id
    self.isIncoming = isIncoming
    self.parties = parties
    self.status = status
    self.isMuted = isMuted
    self.isOnHold = isOnHold
    self.hasVideo = hasVideo
    self.answeredAt = answeredAt
    self.connectedAt = connectedAt
    self.metadata = metadata
  }
}

/// An incoming call for the SDK to present on this device.
public struct IncomingCall: Hashable, Sendable {
  /// The app's identifier for the call.
  public var id: CallID

  /// The parties calling. The system presents the first.
  public var parties: [Party]

  /// Whether the call includes video.
  public var hasVideo: Bool

  /// Values the app attaches to the call, which the SDK passes through unchanged.
  public var metadata: [String: JSONValue]

  /// How this call appears on this device, replacing the configuration's
  /// ``VoIPConfiguration/presentationPolicy`` when set.
  public var presentationPolicy: PresentationPolicy?

  /// Creates an incoming call.
  ///
  /// - Parameters:
  ///   - id: The app's identifier for the call.
  ///   - parties: The parties calling. The system presents the first.
  ///   - hasVideo: Whether the call includes video.
  ///   - metadata: Values the app attaches to the call.
  ///   - presentationPolicy: How this call appears on this device, when it differs from the
  ///     configuration's policy.
  public init(
    id: CallID,
    parties: [Party],
    hasVideo: Bool = false,
    metadata: [String: JSONValue] = [:],
    presentationPolicy: PresentationPolicy? = nil
  ) {
    self.id = id
    self.parties = parties
    self.hasVideo = hasVideo
    self.metadata = metadata
    self.presentationPolicy = presentationPolicy
  }
}

/// An outgoing call to start from this device.
public struct OutgoingCall: Hashable, Sendable {
  /// The app's identifier for the call.
  public var id: CallID

  /// The parties to call. The system presents the first.
  public var parties: [Party]

  /// Whether the call includes video.
  public var hasVideo: Bool

  /// Values the app attaches to the call, which the SDK passes through unchanged.
  public var metadata: [String: JSONValue]

  /// Creates an outgoing call.
  ///
  /// - Parameters:
  ///   - id: The app's identifier for the call.
  ///   - parties: The parties to call. The system presents the first.
  ///   - hasVideo: Whether the call includes video.
  ///   - metadata: Values the app attaches to the call.
  public init(
    id: CallID,
    parties: [Party],
    hasVideo: Bool = false,
    metadata: [String: JSONValue] = [:]
  ) {
    self.id = id
    self.parties = parties
    self.hasVideo = hasVideo
    self.metadata = metadata
  }
}
