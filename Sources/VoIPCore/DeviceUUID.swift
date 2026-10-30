import CryptoKit
public import Foundation

/// The UUID that CallKit and LiveCommunicationKit use for a call on this device.
///
/// The UUID is derived from the call ID alone, so reporting or starting the same call again uses
/// the same UUID, and no table maps one to the other. It is the first 16 bytes of the SHA-256
/// digest of the call ID's UTF-8 bytes, with the version and variant bits of a version 8 UUID
/// (RFC 9562).
///
/// Calling-framework adapters use it to name calls to the system. The app identifies calls by
/// ``CallID`` and never needs it.
///
/// - Parameter id: The app's identifier for the call.
/// - Returns: The call's UUID on this device.
public func deviceUUID(for id: CallID) -> UUID {
  var bytes = Array(SHA256.hash(data: Data(id.rawValue.utf8)).prefix(16))
  bytes[6] = (bytes[6] & 0x0F) | 0x80
  bytes[8] = (bytes[8] & 0x3F) | 0x80
  return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
}
