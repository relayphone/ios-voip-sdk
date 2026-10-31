public import Foundation

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

  /// The most calls this device presents at once, ringing or taking part. Defaults to 2.
  ///
  /// Call previews don't count. An incoming call that would ring beyond this ends with
  /// ``CallFailure/atCapacity``. CallKit and LiveCommunicationKit receive it as their maximum
  /// number of call groups.
  public var maximumCalls: Int

  /// The kinds of handle that the app can call. Defaults to every kind.
  public var supportedHandleTypes: Set<Handle.Kind>

  /// Whether the app's calls can include video, so that the system offers video on its call
  /// screen and in Recents. Defaults to `false`.
  ///
  /// Whether one call has video is ``Call/hasVideo``.
  public var supportsVideo: Bool

  /// Whether the system lists the app's calls in Recents. Defaults to `true`.
  ///
  /// LiveCommunicationKit calls this including conversations in Recents.
  public var includesCallsInRecents: Bool

  /// The name of a sound file in the app's bundle that plays while an incoming call rings, or
  /// `nil` for the system ringtone.
  ///
  /// LiveCommunicationKit calls this the ringtone name.
  public var ringtoneSound: String?

  /// PNG data for a 40 by 40 point template image that the system shows for the app on its call
  /// screen, or `nil` for none.
  public var iconTemplateImageData: Data?

  /// How long the SDK waits at each step of a call before ending it.
  public var deadlines: Deadlines

  /// How long the SDK remembers ended calls, event IDs, and server events for calls it doesn't
  /// know yet. Defaults to 5 minutes.
  ///
  /// A VoIP push for a call that ended within this time doesn't ring again, and a server event
  /// that arrives before its call's VoIP push is applied when the call arrives.
  public var retention: Duration

  /// Creates a configuration.
  ///
  /// - Parameters:
  ///   - capabilities: The optional actions that calls support.
  ///   - presentationPolicy: How incoming calls appear on this device.
  ///   - maximumCalls: The most calls this device presents at once.
  ///   - supportedHandleTypes: The kinds of handle that the app can call.
  ///   - supportsVideo: Whether the app's calls can include video.
  ///   - includesCallsInRecents: Whether the system lists the app's calls in Recents.
  ///   - ringtoneSound: The name of a sound file that plays while a call rings.
  ///   - iconTemplateImageData: PNG data for the app's icon on the system's call screen.
  ///   - deadlines: How long the SDK waits at each step of a call.
  ///   - retention: How long the SDK remembers ended calls and early server events.
  public init(
    capabilities: Capabilities = [.holding, .playingTones],
    presentationPolicy: PresentationPolicy = PresentationPolicy(),
    maximumCalls: Int = 2,
    supportedHandleTypes: Set<Handle.Kind> = Set(Handle.Kind.allCases),
    supportsVideo: Bool = false,
    includesCallsInRecents: Bool = true,
    ringtoneSound: String? = nil,
    iconTemplateImageData: Data? = nil,
    deadlines: Deadlines = Deadlines(),
    retention: Duration = .seconds(300)
  ) {
    self.capabilities = capabilities
    self.presentationPolicy = presentationPolicy
    self.maximumCalls = maximumCalls
    self.supportedHandleTypes = supportedHandleTypes
    self.supportsVideo = supportsVideo
    self.includesCallsInRecents = includesCallsInRecents
    self.ringtoneSound = ringtoneSound
    self.iconTemplateImageData = iconTemplateImageData
    self.deadlines = deadlines
    self.retention = retention
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

  /// How long the SDK waits for the system to activate audio again after an interruption ends or
  /// the media services reset, before a call that takes part and isn't on hold ends. Defaults to
  /// 5 seconds.
  public var audioRecovery: Duration

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
  ///   - audioRecovery: How long the SDK waits for the system to activate audio again after an
  ///     interruption or a media services reset.
  ///   - connect: How long a call may take to connect.
  ///   - reconnect: How long a call may take to reconnect.
  public init(
    ring: Duration = .seconds(60),
    placement: Duration = .seconds(10),
    mediaPreparation: Duration = .seconds(2),
    audioActivation: Duration = .seconds(10),
    audioRecovery: Duration = .seconds(5),
    connect: Duration = .seconds(30),
    reconnect: Duration = .seconds(65)
  ) {
    self.ring = ring
    self.placement = placement
    self.mediaPreparation = mediaPreparation
    self.audioActivation = audioActivation
    self.audioRecovery = audioRecovery
    self.connect = connect
    self.reconnect = reconnect
  }
}
