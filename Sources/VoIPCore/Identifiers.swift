public import Foundation

/// The app's identifier for a call, the same on every device that rings for it.
///
/// LiveCommunicationKit gives each call a per-device UUID. The SDK derives that UUID
/// from the call ID with ``deviceUUID(for:)`` and never shows it to the app, so answered
/// elsewhere, declined elsewhere, push deduplication and server events all refer to the same call.
public struct CallID: RawRepresentable, Hashable, Sendable {
  /// The identifier as the app's servers write it.
  public let rawValue: String

  /// Creates a call ID from the app's identifier.
  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue.utf8.elementsEqual(rhs.rawValue.utf8)
  }

  public func hash(into hasher: inout Hasher) {
    WireValues.hashID(rawValue, into: &hasher)
  }
}

/// A service's alias for an app call, such as a server-assigned call ID or a room ID.
///
/// Bind it with ``VoIPClient/bindRemote(_:to:)`` and keep using the canonical ``CallID``
/// for actions on the call. Aliases are compared by their exact UTF-8 bytes.
public struct RemoteCallID: RawRepresentable, Hashable, Sendable {
  /// The exact identifier supplied by the service.
  public let rawValue: String

  /// Creates an alias of 1–256 Unicode scalars, without control characters or leading or
  /// trailing whitespace.
  public init?(rawValue: String) {
    guard WireValues.isID(rawValue) else { return nil }
    self.rawValue = rawValue
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue.utf8.elementsEqual(rhs.rawValue.utf8)
  }

  public func hash(into hasher: inout Hasher) {
    WireValues.hashID(rawValue, into: &hasher)
  }
}

/// The app's identifier for one server event or VoIP push, used to recognise a repeated delivery
/// of the same event.
public struct EventID: RawRepresentable, Hashable, Sendable {
  /// The identifier as the app's servers write it.
  public let rawValue: String

  /// Creates an event ID from the app's identifier.
  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue.utf8.elementsEqual(rhs.rawValue.utf8)
  }

  public func hash(into hasher: inout Hasher) {
    WireValues.hashID(rawValue, into: &hasher)
  }
}

/// Identifies a local action, including an action the calling framework asked the SDK to perform.
public struct ActionID: RawRepresentable, Hashable, Sendable {
  /// The UUID assigned by the SDK or the calling framework.
  public let rawValue: UUID

  /// Creates an action ID from its UUID.
  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }
}
