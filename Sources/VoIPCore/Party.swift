/// A person or service on the other side of a call, known by one or more handles and an optional
/// display name.
///
/// LiveCommunicationKit's remote members are parties.
public struct Party: Hashable, Sendable {
  /// The handle the system presents for the party: the first of ``handles``.
  public let presentedHandle: Handle

  /// Every handle at which the party can be reached, starting with ``presentedHandle``. It is
  /// never empty.
  public let handles: [Handle]

  /// The name to show for the party, when the app knows one.
  ///
  /// Without it, the system shows the presented handle, or the contact that one of the handles
  /// matches.
  public var displayName: String?

  /// Creates a party reached at a single handle.
  ///
  /// - Parameters:
  ///   - handle: The party's handle, which the system presents.
  ///   - displayName: The name to show for the party, when the app knows one.
  public init(handle: Handle, displayName: String? = nil) {
    presentedHandle = handle
    handles = [handle]
    self.displayName = displayName
  }

  /// Creates a party reached at one or more handles.
  ///
  /// - Parameters:
  ///   - handles: The party's handles. The first is the one the system presents.
  ///   - displayName: The name to show for the party, when the app knows one.
  /// - Throws: ``PartyError/noHandles`` when `handles` is empty.
  public init(handles: [Handle], displayName: String? = nil) throws(PartyError) {
    guard let first = handles.first else { throw .noHandles }
    presentedHandle = first
    self.handles = handles
    self.displayName = displayName
  }
}

/// Why a ``Party`` can't be created.
public enum PartyError: Error, Hashable, Sendable {
  /// The party has no handle, so the system has nothing to present.
  case noHandles
}
