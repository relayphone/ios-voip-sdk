public import Foundation

/// A rejected control's existing human-readable error text.
public struct ControlFailure: LocalizedError, Codable, Equatable, Sendable {
  /// The runtime's unmodified diagnostic message.
  public let message: String
  /// Presents the legacy runtime message through ordinary Swift error handling.
  public var errorDescription: String? { message }
  /// Preserves a legacy rejection message without inventing a structured error code.
  public init(message: String) { self.message = message }
  /// Decodes the existing string-valued error field.
  public init(from decoder: any Decoder) throws {
    message = try decoder.singleValueContainer().decode(String.self)
  }
  /// Writes the existing string-valued error field.
  public func encode(to encoder: any Encoder) throws {
    var value = encoder.singleValueContainer()
    try value.encode(message)
  }
}

/// The distinct result shapes produced by runtime controls.
public enum ControlResult: Codable, Equatable, Sendable {
  /// The current runtime status.
  case status(RuntimeSnapshot)
  /// The retained journal text, which may be empty.
  case events(String)
  /// Whether the installed adapter implements the metadata selector.
  case adapter(metadataSelector: Bool)
  /// The applied incoming filter.
  case incomingFilter(IncomingFilterSnapshot)
  /// Acknowledgement of a fault update with its resulting incoming-report code.
  case faults(incomingErrorCode: Int)
  /// A push accepted for scheduling, correlated by its request identity.
  case push(pushID: UUID)
  /// A reset accepted for the selected provider's opaque identity.
  case reset(provider: String)
  /// Delivered actions whose later journal acknowledgements determine completion.
  case actions(actionIDs: [UUID], transactionID: UUID)

  private enum Key: String, CodingKey {
    case calls, pending, audioActive, sequence, incomingErrorCode, incomingFilter,
      providerConfigurations
    case events, metadataSelector, configured, scheduled, pushID, reset, provider, actionIDs,
      transactionID
  }
  /// Decodes by required result keys, rejecting ambiguous shapes without trial decoding.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: Key.self)
    let keys = Set(values.allKeys)
    let shapes: [(Key, Set<Key>)] = [
      (
        .calls,
        [
          .calls, .pending, .audioActive, .sequence, .incomingErrorCode, .incomingFilter,
          .providerConfigurations,
        ]
      ),
      (.events, [.events]), (.metadataSelector, [.metadataSelector]),
      (.incomingFilter, [.incomingFilter]), (.configured, [.configured, .incomingErrorCode]),
      (.scheduled, [.scheduled, .pushID]), (.reset, [.reset, .provider]),
      (.actionIDs, [.actionIDs, .transactionID]),
    ]
    let selected = shapes.filter {
      keys.contains($0.0) && ($0.0 != .incomingFilter || !keys.contains(.calls))
    }
    guard selected.count == 1, let shape = selected.first, keys.isSubset(of: shape.1) else {
      throw invalidControlValue(decoder.codingPath, "Missing or ambiguous control result shape.")
    }
    switch shape.0 {
    case .calls: self = .status(try RuntimeSnapshot(from: decoder))
    case .events: self = .events(try values.decode(String.self, forKey: .events))
    case .metadataSelector:
      self = .adapter(metadataSelector: try values.decode(Bool.self, forKey: .metadataSelector))
    case .incomingFilter:
      self = .incomingFilter(
        try values.decode(IncomingFilterSnapshot.self, forKey: .incomingFilter))
    case .configured:
      guard try values.decode(Bool.self, forKey: .configured) else {
        throw invalidControlValue(decoder.codingPath, "Fault update was not acknowledged.")
      }
      self = .faults(incomingErrorCode: try values.decode(Int.self, forKey: .incomingErrorCode))
    case .scheduled:
      guard try values.decode(Bool.self, forKey: .scheduled) else {
        throw invalidControlValue(decoder.codingPath, "Push was not scheduled.")
      }
      self = .push(pushID: try values.decode(UUID.self, forKey: .pushID))
    case .reset:
      guard try values.decode(Bool.self, forKey: .reset) else {
        throw invalidControlValue(decoder.codingPath, "Provider reset was not acknowledged.")
      }
      self = .reset(provider: try values.decode(String.self, forKey: .provider))
    case .actionIDs:
      self = .actions(
        actionIDs: try values.decode([UUID].self, forKey: .actionIDs),
        transactionID: try values.decode(UUID.self, forKey: .transactionID))
    default: throw invalidControlValue(decoder.codingPath, "Missing control result discriminator.")
    }
    try validate(at: decoder.codingPath)
  }
  /// Writes the existing operation-specific result object.
  public func encode(to encoder: any Encoder) throws {
    try validate(at: encoder.codingPath)
    var values = encoder.container(keyedBy: Key.self)
    switch self {
    case .status(let snapshot): try snapshot.encode(to: encoder)
    case .events(let text): try values.encode(text, forKey: .events)
    case .adapter(let present): try values.encode(present, forKey: .metadataSelector)
    case .incomingFilter(let filter): try values.encode(filter, forKey: .incomingFilter)
    case .faults(let code):
      try values.encode(true, forKey: .configured)
      try values.encode(code, forKey: .incomingErrorCode)
    case .push(let id):
      try values.encode(true, forKey: .scheduled)
      try values.encode(id, forKey: .pushID)
    case .reset(let provider):
      try values.encode(true, forKey: .reset)
      try values.encode(provider, forKey: .provider)
    case .actions(let ids, let transaction):
      try values.encode(ids, forKey: .actionIDs)
      try values.encode(transaction, forKey: .transactionID)
    }
  }
  private func validate(at path: [any CodingKey]) throws {
    switch self {
    case .faults(let code) where ![0, 4].contains(code):
      throw invalidControlValue(path, "Unsupported incoming-report fault code.")
    case .actions(let ids, _) where ids.isEmpty || Set(ids).count != ids.count:
      throw invalidControlValue(path, "Delivered action identities must be nonempty and distinct.")
    case .reset(let provider) where provider.isEmpty:
      throw invalidControlValue(path, "Missing provider identity.")
    case .status(let snapshot):
      guard [0, 4].contains(snapshot.incomingErrorCode),
        Set(snapshot.calls.map(\.state.uuid)).count == snapshot.calls.count,
        Set(snapshot.providerConfigurations.map(\.provider)).count
          == snapshot.providerConfigurations.count,
        snapshot.providerConfigurations.allSatisfy({ !$0.provider.isEmpty })
      else {
        throw invalidControlValue(path, "Inconsistent runtime status.")
      }
    default: break
    }
  }
}

/// A response correlated to one request and one runtime invocation.
public struct ControlResponse: Codable, Equatable, Sendable {
  /// The original mailbox request identity.
  public let id: UUID
  /// The runtime invocation that produced this response.
  public let target: RuntimeIdentity
  /// Either one successful result or one rejection.
  public let outcome: Outcome

  /// A result is accepted or scheduled; eventual completion still comes from the journal.
  public enum Outcome: Equatable, Sendable {
    /// The operation produced its specific result shape.
    case success(ControlResult)
    /// The runtime rejected the operation.
    case failure(ControlFailure)
  }
  /// Creates a response without changing request admission or retry policy.
  public init(id: UUID, target: RuntimeIdentity, outcome: Outcome) {
    self.id = id
    self.target = target
    self.outcome = outcome
  }
  /// Returns the accepted result or throws the runtime's original rejection message.
  public func get() throws(ControlFailure) -> ControlResult {
    switch outcome {
    case .success(let result): return result
    case .failure(let failure): throw failure
    }
  }
  private enum Key: String, CodingKey { case id, success, result, error }
  /// Decodes the flat v1 envelope, requiring exactly one outcome.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: Key.self)
    id = try values.decode(UUID.self, forKey: .id)
    target = try RuntimeIdentity(from: decoder)
    if try values.decode(Bool.self, forKey: .success) {
      guard !values.contains(.error) else {
        throw invalidControlValue(decoder.codingPath, "Successful control contains an error.")
      }
      outcome = .success(try values.decode(ControlResult.self, forKey: .result))
    } else {
      guard !values.contains(.result) else {
        throw invalidControlValue(decoder.codingPath, "Rejected control contains a result.")
      }
      outcome = .failure(try values.decode(ControlFailure.self, forKey: .error))
    }
  }
  /// Writes the existing identity, success flag and result or error fields.
  public func encode(to encoder: any Encoder) throws {
    try target.encode(to: encoder)
    var values = encoder.container(keyedBy: Key.self)
    try values.encode(id, forKey: .id)
    switch outcome {
    case .success(let result):
      try values.encode(true, forKey: .success)
      try values.encode(result, forKey: .result)
    case .failure(let failure):
      try values.encode(false, forKey: .success)
      try values.encode(failure, forKey: .error)
    }
  }
}
