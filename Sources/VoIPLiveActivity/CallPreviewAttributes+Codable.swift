import Foundation

#if SWIFT_PACKAGE
  import VoIPCore
#endif

extension CallPreviewAttributes: Codable {
  private enum CodingKeys: String, CodingKey {
    case callID = "callId"
    case parties, hasVideo, metadata
  }

  /// Creates attributes by decoding them from their JSON object.
  ///
  /// - Parameter decoder: The decoder to read from.
  /// - Throws: `DecodingError` when the value isn't the attributes' JSON: `callId` is missing or
  ///   blank, `parties` is missing, or a party's handle isn't valid.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let id = try values.decode(String.self, forKey: .callID)
    guard id.contains(where: { !$0.isWhitespace }) else {
      throw DecodingError.dataCorruptedError(
        forKey: .callID, in: values, debugDescription: "Empty call ID")
    }
    self.init(
      callID: CallID(rawValue: id),
      parties: try values.decode([PartyBody].self, forKey: .parties).map(\.party),
      hasVideo: try values.decodeIfPresent(Bool.self, forKey: .hasVideo) ?? false,
      metadata: try values.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:])
  }

  /// Encodes the attributes as their JSON object.
  ///
  /// - Parameter encoder: The encoder to write to.
  /// - Throws: `EncodingError` when the encoder can't write a value, such as a NaN number in
  ///   ``metadata``.
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(callID.rawValue, forKey: .callID)
    try values.encode(parties.map(PartyBody.init), forKey: .parties)
    try values.encode(hasVideo, forKey: .hasVideo)
    try values.encode(metadata, forKey: .metadata)
  }

  /// The most bytes that a Live Activity's attributes and content state may take together.
  static let maximumSize = 4096

  /// Whether the attributes and a content state together fit the system's limit for a Live
  /// Activity, measured as JSON.
  func fits(with state: ContentState) -> Bool {
    let encoder = JSONEncoder()
    guard let attributes = try? encoder.encode(self), let state = try? encoder.encode(state) else {
      return false
    }
    return attributes.count + state.count <= Self.maximumSize
  }
}

extension CallPreviewAttributes.ContentState: Codable {
  private enum CodingKeys: String, CodingKey {
    case status, startedAt, statusText, snippet, isJoinable
  }

  /// Creates a content state by decoding it from its JSON object.
  ///
  /// - Parameter decoder: The decoder to read from.
  /// - Throws: `DecodingError` when the value isn't the content state's JSON: `status`,
  ///   `startedAt` or `isJoinable` is missing, or `status` isn't a ``CallPreviewStatus``.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      status: try values.decode(CallPreviewStatus.self, forKey: .status),
      startedAt: Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .startedAt)),
      statusText: try values.decodeIfPresent(String.self, forKey: .statusText),
      snippet: try values.decodeIfPresent(String.self, forKey: .snippet),
      isJoinable: try values.decode(Bool.self, forKey: .isJoinable))
  }

  /// Encodes the content state as its JSON object, with ``startedAt`` as a Unix timestamp in
  /// seconds.
  ///
  /// - Parameter encoder: The encoder to write to.
  /// - Throws: `EncodingError` when the encoder can't write a value.
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(status, forKey: .status)
    try values.encode(startedAt.timeIntervalSince1970, forKey: .startedAt)
    try values.encodeIfPresent(statusText, forKey: .statusText)
    try values.encodeIfPresent(snippet, forKey: .snippet)
    try values.encode(isJoinable, forKey: .isJoinable)
  }
}

/// A party as the attributes' JSON writes it: like the caller of the SDK's default VoIP push,
/// with any further handles in `additionalHandles`.
private struct PartyBody: Codable {
  let party: Party

  private enum CodingKeys: String, CodingKey {
    case displayName, additionalHandles
  }

  init(_ party: Party) {
    self.party = party
  }

  init(from decoder: any Decoder) throws {
    let presented = try HandleBody(from: decoder).handle
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let others = try values.decodeIfPresent([HandleBody].self, forKey: .additionalHandles) ?? []
    let name = try values.decodeIfPresent(String.self, forKey: .displayName)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = name?.isEmpty == false ? name : nil
    // Never fails: the presented handle comes first.
    guard
      let party = try? Party(handles: [presented] + others.map(\.handle), displayName: displayName)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .additionalHandles, in: values, debugDescription: "A party needs a handle")
    }
    self.party = party
  }

  func encode(to encoder: any Encoder) throws {
    try HandleBody(party.presentedHandle).encode(to: encoder)
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encodeIfPresent(party.displayName, forKey: .displayName)
    let others = party.handles.dropFirst()
    if !others.isEmpty {
      try values.encode(others.map(HandleBody.init), forKey: .additionalHandles)
    }
  }
}

/// A handle as the attributes' JSON writes it, with the rules of the SDK's default VoIP push.
private struct HandleBody: Codable {
  let handle: Handle

  private enum HandleType: String, Codable {
    case phone, email, generic
  }

  private enum CodingKeys: String, CodingKey {
    case handleType, value
  }

  init(_ handle: Handle) {
    self.handle = handle
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    var value = try values.decode(String.self, forKey: .value)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let kind: Handle.Kind
    switch try values.decode(HandleType.self, forKey: .handleType) {
    case .phone:
      kind = .phoneNumber
      value.removeAll { " ()-.".contains($0) }
    case .email:
      kind = .emailAddress
      let parts = value.split(separator: "@", omittingEmptySubsequences: false)
      guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
        !value.contains(where: \.isWhitespace)
      else {
        throw DecodingError.dataCorruptedError(
          forKey: .value, in: values, debugDescription: "Invalid email address")
      }
    case .generic:
      kind = .generic
    }
    do {
      handle = try Handle(kind: kind, value: value)
    } catch {
      throw DecodingError.dataCorruptedError(
        forKey: .value, in: values, debugDescription: "Invalid handle: \(error)")
    }
  }

  func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    let type: HandleType =
      switch handle.kind {
      case .phoneNumber: .phone
      case .emailAddress: .email
      case .generic: .generic
      }
    try values.encode(type, forKey: .handleType)
    try values.encode(handle.value, forKey: .value)
  }
}
