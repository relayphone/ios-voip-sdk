public import Foundation

/// The app's identifier for a call, the same on every device that rings for it.
///
/// CallKit and LiveCommunicationKit give each call a per-device UUID. The SDK derives that UUID
/// from the call ID with ``deviceUUID(for:)`` and never shows it to the app, so answered
/// elsewhere, declined elsewhere, push deduplication and server events all refer to the same call.
public struct CallID: RawRepresentable, Hashable, Sendable {
  /// The identifier as the app's servers write it.
  public let rawValue: String

  /// Creates a call ID from the app's identifier.
  public init(rawValue: String) {
    self.rawValue = rawValue
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
}

/// Identifies one action that the calling framework asked the SDK to perform, so that the SDK can
/// fulfil or fail it.
public struct ActionID: RawRepresentable, Hashable, Sendable {
  /// The identifier of the system's action, such as a CallKit action's UUID.
  public let rawValue: UUID

  /// Creates an action ID from the system action's identifier.
  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }
}
