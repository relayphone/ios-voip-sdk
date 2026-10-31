/// An address at which a party can be reached: a phone number, an email address, or a generic
/// value such as an app account, as in Apple's handle types.
public struct Handle: Hashable, Sendable {
  /// The kind of address a handle holds, matching LiveCommunicationKit's handle types.
  public enum Kind: Hashable, Sendable, CaseIterable {
    /// A phone number in E.164 format, such as `+14155550123`.
    case phoneNumber
    /// An email address.
    case emailAddress
    /// Any other value at which the app reaches a party, such as an account identifier.
    case generic
  }

  /// The kind of address.
  public let kind: Kind

  /// The address, exactly as it was validated.
  public let value: String

  /// Creates a handle, validating the value for its kind.
  ///
  /// A phone number must be in E.164 format: a plus sign followed by 2 to 15 digits, the first of
  /// which isn't zero. The SDK doesn't reformat numbers, so convert other formats before creating
  /// the handle. An email address or a generic value must contain a non-whitespace character.
  ///
  /// - Parameters:
  ///   - kind: The kind of address.
  ///   - value: The address.
  /// - Throws: ``HandleError/empty`` when the value is empty or whitespace, or
  ///   ``HandleError/invalidPhoneNumber`` when a phone number isn't in E.164 format.
  public init(kind: Kind, value: String) throws(HandleError) {
    guard value.contains(where: { !$0.isWhitespace }) else { throw .empty }
    if kind == .phoneNumber, !Self.isE164(value) { throw .invalidPhoneNumber }
    self.kind = kind
    self.value = value
  }

  private static func isE164(_ value: String) -> Bool {
    let digits = value.utf8.dropFirst()
    return value.utf8.first == UInt8(ascii: "+")
      && (2...15).contains(digits.count)
      && digits.first != UInt8(ascii: "0")
      && digits.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
  }
}

/// Why a value isn't a valid ``Handle``.
public enum HandleError: Error, Hashable, Sendable {
  /// The value is empty or contains only whitespace.
  case empty
  /// A phone number isn't in E.164 format: a plus sign followed by 2 to 15 digits, the first of
  /// which isn't zero.
  case invalidPhoneNumber
}
