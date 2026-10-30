/// How the SDK presents and controls calls in this app.
public struct VoIPConfiguration: Hashable, Sendable {
  /// The optional actions that calls in this app support.
  public struct Capabilities: OptionSet, Hashable, Sendable {
    /// Calls can be put on hold. LiveCommunicationKit calls this pausing.
    public static let holding = Capabilities(rawValue: 1 << 0)
    /// Calls can play DTMF tones.
    public static let playingTones = Capabilities(rawValue: 1 << 1)
    /// Calls can be merged and unmerged. The app mixes the media of merged calls.
    public static let merging = Capabilities(rawValue: 1 << 2)

    /// The capabilities as a bit field.
    public let rawValue: Int

    /// Creates capabilities from a bit field.
    public init(rawValue: Int) {
      self.rawValue = rawValue
    }
  }

  /// The optional actions that calls support. Defaults to holding and playing tones; merging is
  /// off.
  public var capabilities: Capabilities

  /// How incoming calls appear on this device, unless a call sets its own policy.
  public var presentationPolicy: PresentationPolicy

  /// How long the SDK waits at each step of a call before ending it.
  public var deadlines: Deadlines

  /// Creates a configuration.
  ///
  /// - Parameters:
  ///   - capabilities: The optional actions that calls support.
  ///   - presentationPolicy: How incoming calls appear on this device.
  ///   - deadlines: How long the SDK waits at each step of a call.
  public init(
    capabilities: Capabilities = [.holding, .playingTones],
    presentationPolicy: PresentationPolicy = PresentationPolicy(),
    deadlines: Deadlines = Deadlines()
  ) {
    self.capabilities = capabilities
    self.presentationPolicy = presentationPolicy
    self.deadlines = deadlines
  }
}

/// How long the SDK waits at each step of a call before ending it.
///
/// When a deadline passes, the call ends: as ``EndReason/unanswered`` for the ring deadline, and
/// as ``EndReason/failed(_:)`` for the others.
public struct Deadlines: Hashable, Sendable {
  /// How long an incoming call rings, or an outgoing call dials, before it ends unanswered.
  /// Defaults to 60 seconds.
  public var ring: Duration

  /// How long the app has to place an outgoing call, or join a call, after it is requested.
  /// Defaults to 10 seconds.
  public var placement: Duration

  /// How long the SDK waits for the call's media to be prepared before it completes an answer,
  /// start or join. Defaults to 2 seconds.
  public var mediaPreparation: Duration

  /// How long the SDK waits for the system to activate audio after an answer, start or join
  /// completes. Defaults to 10 seconds.
  public var audioActivation: Duration

  /// How long an answered or joined call may take to connect. Defaults to 30 seconds.
  public var connect: Duration

  /// How long a call may take to reconnect. Defaults to 65 seconds.
  public var reconnect: Duration

  /// Creates deadlines.
  ///
  /// - Parameters:
  ///   - ring: How long a call rings or dials before it ends unanswered.
  ///   - placement: How long the app has to place or join a call.
  ///   - mediaPreparation: How long the SDK waits for media to be prepared.
  ///   - audioActivation: How long the SDK waits for the system to activate audio.
  ///   - connect: How long a call may take to connect.
  ///   - reconnect: How long a call may take to reconnect.
  public init(
    ring: Duration = .seconds(60),
    placement: Duration = .seconds(10),
    mediaPreparation: Duration = .seconds(2),
    audioActivation: Duration = .seconds(10),
    connect: Duration = .seconds(30),
    reconnect: Duration = .seconds(65)
  ) {
    self.ring = ring
    self.placement = placement
    self.mediaPreparation = mediaPreparation
    self.audioActivation = audioActivation
    self.connect = connect
    self.reconnect = reconnect
  }
}
