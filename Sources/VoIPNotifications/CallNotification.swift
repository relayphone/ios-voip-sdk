#if SWIFT_PACKAGE
  public import VoIPCore
#endif

/// A communication notification about a call: the system shows it as coming from the caller, and
/// a Focus lets it through only for the people it allows.
///
/// ``CallNotifier`` makes one for each call that Do Not Disturb or a Focus filtered. It holds no
/// UserNotifications or Intents types, so a ``CallNotificationCenter`` decides how to post it.
///
/// A call notification never rings: its interruption level is passive or active, and it plays the
/// default sound or none. The SDK offers no Time Sensitive or Critical level and no custom sound,
/// because those would get through a Focus for callers it doesn't allow (see ADR 0009).
public struct CallNotification: Hashable, Sendable {
  /// What a call notification tells the user.
  public enum Kind: Hashable, Sendable {
    /// The call is live, and the user can join it from its call preview.
    case incoming
    /// The call ended without being joined on this device.
    case missed
  }

  /// How a call notification interrupts the user, when the user's Focus lets it through.
  public enum InterruptionLevel: Hashable, Sendable {
    /// The system adds the notification to Notification Center without lighting the screen or
    /// playing a sound.
    case passive
    /// The system presents the notification at once, lighting the screen and playing its sound.
    case active
  }

  /// The call the notification is about. A notification replaces any other for the same call.
  public let callID: CallID

  /// What the notification tells the user.
  public let kind: Kind

  /// Whether the call includes video.
  public let hasVideo: Bool

  /// The party calling, as the system shows it. Focus matches the people it allows by the
  /// party's handles.
  public var caller: Party

  /// The notification's text, such as "Incoming call".
  public var body: String

  /// How the notification interrupts the user.
  public var interruptionLevel: InterruptionLevel

  /// Whether the notification plays the system's default notification sound.
  public var playsSound: Bool

  /// Creates a call notification.
  ///
  /// - Parameters:
  ///   - callID: The call the notification is about.
  ///   - kind: What the notification tells the user.
  ///   - caller: The party calling.
  ///   - hasVideo: Whether the call includes video.
  ///   - body: The notification's text. Defaults to ``defaultBody(for:hasVideo:)``.
  ///   - interruptionLevel: How the notification interrupts the user.
  ///   - playsSound: Whether the notification plays the default notification sound.
  public init(
    callID: CallID,
    kind: Kind,
    caller: Party,
    hasVideo: Bool = false,
    body: String? = nil,
    interruptionLevel: InterruptionLevel = .active,
    playsSound: Bool = true
  ) {
    self.callID = callID
    self.kind = kind
    self.hasVideo = hasVideo
    self.caller = caller
    self.body = body ?? Self.defaultBody(for: kind, hasVideo: hasVideo)
    self.interruptionLevel = interruptionLevel
    self.playsSound = playsSound
  }

  /// The text of a notification whose body the app doesn't set, in English: "Incoming call",
  /// "Incoming video call", "Missed call" or "Missed video call".
  ///
  /// Localize the text with ``CallNotifier/Options/customize``.
  ///
  /// - Parameters:
  ///   - kind: What the notification tells the user.
  ///   - hasVideo: Whether the call includes video.
  /// - Returns: The notification's text.
  public static func defaultBody(for kind: Kind, hasVideo: Bool) -> String {
    switch (kind, hasVideo) {
    case (.incoming, false): "Incoming call"
    case (.incoming, true): "Incoming video call"
    case (.missed, false): "Missed call"
    case (.missed, true): "Missed video call"
    }
  }
}
