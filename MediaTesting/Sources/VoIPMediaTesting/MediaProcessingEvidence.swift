/// Evidence for adapter intent and effective processing at the terminal check read.
public struct MediaProcessingEvidence: Encodable, Sendable {
  /// One independently checked software effect.
  public enum Effect: String, Codable, CaseIterable, Sendable { case aec, ns, agc }
  /// The adapter's requested configuration or the engine's effective configuration.
  public struct Configuration: Codable, Equatable, Sendable {
    /// Echo cancellation enabled.
    public let aec: Bool
    /// Noise suppression enabled.
    public let ns: Bool
    /// Automatic gain control enabled.
    public let agc: Bool
    /// Creates a configuration from actual option or state values.
    public init(aec: Bool, ns: Bool, agc: Bool) {
      self.aec = aec
      self.ns = ns
      self.agc = agc
    }
    fileprivate subscript(effect: Effect) -> Bool {
      switch effect {
      case .aec: aec
      case .ns: ns
      case .agc: agc
      }
    }
  }
  /// Expected effective and requested software effects.
  public let expected: Configuration
  /// Adapter options captured immediately before applying them; absent if never applied.
  public let applied: Configuration?
  /// Effective software effects at checkRead.
  public let active: Configuration
  /// Whether the engine was running at checkRead.
  public let engineRunning: Bool
  /// LiveKit requested values observed at checkRead; missing keys remain unobserved.
  public let requested: [Effect: Bool]
  /// Effects whose transient LiveKit requested values were unavailable at checkRead.
  public var requestedUnobserved: [Effect] {
    Effect.allCases.filter { requested[$0] == nil }
  }
  /// Requires adapter intent, effective state and a running engine; observed requests must match.
  public var passed: Bool {
    engineRunning && applied == expected && active == expected
      && requested.allSatisfy { expected[$0.key] == $0.value }
  }
  /// Captures the actual adapter options and terminal state without inferring missing requests.
  public init(
    expected: Configuration, applied: Configuration?, active: Configuration,
    engineRunning: Bool, requested: [Effect: Bool]
  ) {
    self.expected = expected
    self.applied = applied
    self.active = active
    self.engineRunning = engineRunning
    self.requested = requested
  }

  private enum CodingKeys: String, CodingKey {
    case expected, applied, active, engineRunning, requested, requestedUnobserved
  }
  /// Encodes observed requests and explicitly lists unavailable effects.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(expected, forKey: .expected)
    try container.encodeIfPresent(applied, forKey: .applied)
    try container.encode(active, forKey: .active)
    try container.encode(engineRunning, forKey: .engineRunning)
    try container.encode(
      Dictionary(uniqueKeysWithValues: requested.map { ($0.key.rawValue, $0.value) }),
      forKey: .requested)
    try container.encode(requestedUnobserved, forKey: .requestedUnobserved)
  }
}
