/// The account that owns a calling line.
public struct AccountID: RawRepresentable, Hashable, Sendable {
  /// The exact identifier supplied by the service.
  public let rawValue: String

  /// Creates an account ID of 1–256 Unicode scalars with no control characters or surrounding whitespace.
  public init?(rawValue: String) {
    guard WireValues.isID(rawValue) else { return nil }
    self.init(validated: rawValue)
  }

  fileprivate init(validated: String) { rawValue = validated }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue.utf8.elementsEqual(rhs.rawValue.utf8)
  }

  public func hash(into hasher: inout Hasher) {
    WireValues.hashID(rawValue, into: &hasher)
  }
}

/// The service's identifier for a calling line within an account.
public struct LineID: RawRepresentable, Hashable, Sendable {
  /// The exact identifier supplied by the service.
  public let rawValue: String

  /// Creates a line ID of 1–256 Unicode scalars with no control characters or surrounding whitespace.
  public init?(rawValue: String) {
    guard WireValues.isID(rawValue) else { return nil }
    self.init(validated: rawValue)
  }

  fileprivate init(validated: String) { rawValue = validated }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue.utf8.elementsEqual(rhs.rawValue.utf8)
  }

  public func hash(into hasher: inout Hasher) {
    WireValues.hashID(rawValue, into: &hasher)
  }
}

/// The calling identity and display label recorded with a call at admission.
public struct CallingLine: Hashable, Sendable {
  /// The implicit line used when the app doesn't specify one.
  public static let `default` = CallingLine(
    accountID: AccountID(validated: "default"), id: LineID(validated: "default"), label: "Default")

  /// The account that owns this line.
  public let accountID: AccountID
  /// This line's identifier within its account.
  public let id: LineID
  /// The line's display name.
  public let label: String

  /// Creates a calling line with its account, identifier and display label.
  public init(accountID: AccountID, id: LineID, label: String) {
    self.accountID = accountID
    self.id = id
    self.label = label
  }
}

#if SWIFT_PACKAGE
  extension SpecV0.Line {
    package var callingLine: CallingLine {
      CallingLine(
        accountID: AccountID(validated: accountID.rawValue), id: id.lineID, label: label)
    }
  }

  extension SpecV0.ID {
    package var lineID: LineID { LineID(validated: rawValue) }
  }
#endif
