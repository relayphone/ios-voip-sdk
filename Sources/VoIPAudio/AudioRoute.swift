/// Where calls' audio plays and records: the built-in receiver or speaker, wired headphones, a
/// Bluetooth device, AirPlay or CarPlay.
public struct AudioRoute: Identifiable, Hashable, Sendable {
  /// Identifies a route while its device stays connected.
  public struct ID: RawRepresentable, Hashable, Sendable {
    /// The identifier, derived from the system's identifier for the route's device.
    public let rawValue: String

    /// Creates a route ID from an identifier that ``AudioRoute/id`` returned.
    public init(rawValue: String) {
      self.rawValue = rawValue
    }
  }

  /// The kind of device a route uses.
  public enum Kind: Hashable, Sendable {
    /// The receiver at the top of an iPhone, with the built-in microphone.
    case builtInReceiver
    /// The built-in speaker, with the built-in microphone.
    case builtInSpeaker
    /// Wired headphones or a wired headset.
    case headphones
    /// A Bluetooth device, such as AirPods or a hearing device.
    case bluetooth
    /// An AirPlay device.
    case airPlay
    /// CarPlay.
    case carAudio
    /// A USB audio device.
    case usbAudio
    /// Another device, such as an HDMI display.
    case other
  }

  /// The route's identifier, which ``AudioSessionAdapter/selectRoute(_:)`` takes.
  public let id: ID

  /// The kind of device the route uses.
  public let kind: Kind

  /// The name the system gives the route's device, such as "AirPods Pro". Label built-in routes
  /// by their ``kind``.
  public let name: String

  /// Creates a route.
  ///
  /// - Parameters:
  ///   - id: The route's identifier.
  ///   - kind: The kind of device the route uses.
  ///   - name: The name the system gives the route's device.
  public init(id: ID, kind: Kind, name: String) {
    self.id = id
    self.kind = kind
    self.name = name
  }
}

/// Why the SDK couldn't select an audio route.
public enum AudioRouteError: Error, Hashable, Sendable {
  /// The route isn't available.
  case unavailable
  /// The audio session refused to change the route.
  case refused
}
