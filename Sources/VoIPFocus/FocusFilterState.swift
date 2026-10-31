public import Foundation

/// What the app's Focus filter last asked for: unknown, inactive, or active with the filter's
/// settings.
///
/// The system runs a Focus filter when a Focus that has it turns on, and again when that Focus
/// turns off, with every setting reset to its default. It tells the app nothing else, so a filter
/// whose settings equal their defaults is ``inactive(since:)``: the defaults are the app's
/// behaviour outside a Focus. Give the filter's settings the defaults that the app follows when no
/// Focus is on.
///
/// The state doesn't say whether a Focus is on. A Focus without the filter still filters the app's
/// incoming calls, and the state stays as it was. Use it to choose how the app's servers present
/// each call to this device, such as ringing or a call preview, not to tell the user that a
/// Focus is on.
///
/// `Settings` is the app's own type for what the filter asks for, such as who may ring this
/// device.
///
/// ## JSON
///
/// The state encodes to a JSON object that the app can send to its servers. `since` is in
/// seconds since 1970 (Unix time), and `settings` is the app's settings as they encode:
///
/// ```json
/// {"state": "unknown"}
/// {"state": "inactive", "since": 1761948000}
/// {"state": "active", "since": 1761948000, "settings": {"ringing": "favorites"}}
/// ```
public enum FocusFilterState<Settings: Codable & Hashable & Sendable>: Hashable, Sendable {
  /// The filter hasn't run since the app was installed, or its last state can't be read.
  ///
  /// The user may not have added the filter to any Focus. This isn't inactive: a Focus might be
  /// on.
  case unknown

  /// The filter last ran with its default settings: the Focus that has it turned off, or one
  /// that keeps every default turned on.
  ///
  /// - Parameter since: When the filter started asking for its defaults.
  case inactive(since: Date)

  /// A Focus that has the filter is on and asks for these settings.
  ///
  /// - Parameters:
  ///   - settings: What the Focus asks for.
  ///   - since: When the filter started asking for these settings.
  case active(Settings, since: Date)
}

extension FocusFilterState {
  /// The state of a Focus filter that runs with these settings: inactive when they equal the
  /// filter's defaults, and active otherwise.
  init(_ settings: Settings, defaults: Settings, since: Date) {
    self = settings == defaults ? .inactive(since: since) : .active(settings, since: since)
  }

  /// Whether both states ask for the same thing, whenever they started.
  func asksForTheSame(as other: Self) -> Bool {
    switch (self, other) {
    case (.unknown, .unknown), (.inactive, .inactive): true
    case (.active(let settings, _), .active(let otherSettings, _)): settings == otherSettings
    default: false
    }
  }
}

extension FocusFilterState: Codable {
  private enum CodingKeys: String, CodingKey {
    case state
    case since
    case settings
  }

  private enum Kind: String, Codable {
    case unknown
    case inactive
    case active
  }

  /// Creates a state by decoding it from its JSON object.
  ///
  /// - Parameter decoder: The decoder to read from.
  /// - Throws: `DecodingError` when the object isn't a Focus filter state, or its settings don't
  ///   decode as `Settings`.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .state) {
    case .unknown:
      self = .unknown
    case .inactive:
      self = .inactive(since: try Self.decodeSince(from: container))
    case .active:
      let settings = try container.decode(Settings.self, forKey: .settings)
      self = .active(settings, since: try Self.decodeSince(from: container))
    }
  }

  /// Encodes the state as its JSON object.
  ///
  /// - Parameter encoder: The encoder to write to.
  /// - Throws: An error when the settings can't be encoded.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .unknown:
      try container.encode(Kind.unknown, forKey: .state)
    case .inactive(let since):
      try container.encode(Kind.inactive, forKey: .state)
      try container.encode(since.timeIntervalSince1970, forKey: .since)
    case .active(let settings, let since):
      try container.encode(Kind.active, forKey: .state)
      try container.encode(since.timeIntervalSince1970, forKey: .since)
      try container.encode(settings, forKey: .settings)
    }
  }

  private static func decodeSince(from container: KeyedDecodingContainer<CodingKeys>) throws
    -> Date
  {
    Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .since))
  }
}
