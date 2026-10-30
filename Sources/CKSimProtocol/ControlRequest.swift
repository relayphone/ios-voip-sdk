import Foundation

/// A validated version-one runtime mailbox request with operation-specific parameters.
public struct ControlRequest: Codable, Equatable, Sendable {
  /// The request's filename and response correlation identifier.
  public let id: UUID
  /// The exact runtime invocation addressed by this request.
  public let target: RuntimeIdentity
  /// The control to perform after mailbox ownership has been checked.
  public let operation: Operation

  /// A runtime control and only the parameters that control accepts.
  public enum Operation: Equatable, Sendable {
    /// Read the current runtime snapshot.
    case status
    /// Read the retained event journal.
    case events
    /// Inspect the installed PushKit adapter.
    case inspectAdapter
    /// Configure the incoming-report filter.
    case incomingFilter(FilterReason)
    /// Apply a nonempty partial fault update; omitted settings retain their values.
    case faults([FaultChange])
    /// Schedule a push with explicit reporting intent and application data.
    case push(PushPayload, mustReport: Bool)
    /// Reset the selected provider when no runtime actions are pending.
    case reset
    /// Deliver a call control after validating current provider state.
    case call(CallControl)

    /// The existing version-one discriminator, also used in journal diagnostics.
    public var name: String {
      switch self {
      case .status: "status"
      case .events: "events"
      case .inspectAdapter: "inspect-adapter"
      case .incomingFilter: "incoming-filter"
      case .faults: "faults"
      case .push: "push"
      case .reset: "reset"
      case .call(let control): control.name
      }
    }
  }

  /// One independently configurable fault setting.
  public enum FaultChange: Equatable, Sendable {
    /// Retain stale runtime audio state when enabled.
    case staleAudio(Bool)
    /// Delay report callbacks by 0–120,000 milliseconds.
    case reportCallbackDelayMS(Int)
    /// Invalidate the selected provider during a multi-action handoff.
    case invalidateDuringHandoff(Bool)
    /// Use incoming-report error code zero or four.
    case incomingErrorCode(Int)
  }

  private enum FaultKey: String, CodingKey, CaseIterable {
    case staleAudio, reportCallbackDelayMS, invalidateDuringHandoff, incomingErrorCode
  }

  private static func faultKey(_ change: FaultChange) -> FaultKey {
    switch change {
    case .staleAudio: .staleAudio
    case .reportCallbackDelayMS: .reportCallbackDelayMS
    case .invalidateDuringHandoff: .invalidateDuringHandoff
    case .incomingErrorCode: .incomingErrorCode
    }
  }

  /// A supported incoming-report filtering policy.
  public enum FilterReason: String, Codable, CaseIterable, Sendable {
    /// Allow incoming reports.
    case none
    /// Simulate Do Not Disturb filtering.
    case doNotDisturb = "do-not-disturb"
    /// Simulate restricted sharing.
    case restrictedSharingMode = "restricted-sharing-mode"
    /// Simulate protection of the current call.
    case callIsProtected = "call-is-protected"
    /// Simulate sensitive-participant filtering.
    case sensitiveParticipants = "sensitive-participants"
  }

  /// The source of controls for which the runtime models application requests.
  public enum Origin: Sendable {
    /// A runtime system control.
    case system
    /// An LCK application request.
    case application
  }

  /// Call controls with their required UUIDs and action-specific parameters.
  public enum CallControl: Equatable, Sendable {
    /// Answer a ringing call.
    case answer(UUID)
    /// Decline a ringing call.
    case decline(UUID)
    /// End a call.
    case end(UUID)
    /// Change the held state, optionally through an LCK application request.
    case hold(UUID, held: Bool, origin: Origin)
    /// Merge with another call through the supported LCK grouping path.
    case merge(UUID, with: UUID, origin: Origin)
    /// Remove a call from its group.
    case unmerge(UUID, origin: Origin)
    /// Change the muted state.
    case mute(UUID, muted: Bool)
    /// Play validated DTMF digits.
    case tones(UUID, digits: String)
    /// Hold the active call and answer a different ringing call.
    case holdAndAccept(UUID, active: UUID)
    /// End the active call and answer a different ringing call.
    case endAndAccept(UUID, active: UUID)
    /// End the held call, hold the active call and answer the ringing call.
    case endHeldAndAccept(UUID, active: UUID, held: UUID)

    /// The call to which the primary action applies.
    public var callID: UUID {
      switch self {
      case .answer(let id), .decline(let id), .end(let id), .hold(let id, _, _),
        .merge(let id, _, _), .unmerge(let id, _), .mute(let id, _), .tones(let id, _),
        .holdAndAccept(let id, _), .endAndAccept(let id, _), .endHeldAndAccept(let id, _, _):
        id
      }
    }

    /// Only hold and grouping controls can originate in an application.
    public var origin: Origin {
      switch self {
      case .hold(_, _, let origin), .merge(_, _, let origin), .unmerge(_, let origin): origin
      default: .system
      }
    }

    /// The existing call-control wire discriminator.
    public var name: String {
      switch self {
      case .answer: "answer"
      case .decline: "decline"
      case .end: "end"
      case .hold: "hold"
      case .merge: "merge"
      case .unmerge: "unmerge"
      case .mute: "mute"
      case .tones: "tones"
      case .holdAndAccept: "hold-and-accept"
      case .endAndAccept: "end-and-accept"
      case .endHeldAndAccept: "end-held-and-accept"
      }
    }
  }

  /// A request that cannot be executed without changing its meaning.
  public enum ValidationError: Error, Equatable, Sendable {
    /// The discriminator is not a supported control.
    case unsupportedOperation(String)
    /// Known control parameters were supplied to a different operation.
    case unexpectedParameters([String])
    /// DTMF requires 1–64 supported ASCII digits.
    case invalidDigits
    /// A multi-call control must refer to distinct calls.
    case duplicateCallIDs
    /// Optional envelope metadata names an unsupported schema or transport.
    case unsupportedEnvelope
    /// Fault changes must be nonempty, unique and within supported ranges.
    case invalidFaults
    /// The encoded application push object exceeds 5,120 bytes.
    case payloadTooLarge
    /// The mailbox file exceeds 65,536 bytes.
    case requestTooLarge
    /// A JSON object repeats a field, including an escaped spelling of that field.
    case duplicateField(String)
    /// An integer field uses a fractional or exponent token.
    case invalidInteger(String)
    /// An application integer is outside the exact signed/unsigned 64-bit range.
    case unsupportedPushInteger
  }

  /// The attributable request header, which never authorizes execution by itself.
  public struct Header: Codable, Equatable, Sendable {
    /// The request's correlation identifier.
    public let id: UUID
    /// The addressed runtime invocation.
    public let target: RuntimeIdentity
    /// The untrusted discriminator retained for rejection diagnostics.
    public let operationName: String
    private enum CodingKeys: String, CodingKey { case id, operation }

    /// Reads required header scalars without interpreting operation parameters.
    public init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      id = try values.decode(UUID.self, forKey: .id)
      target = try RuntimeIdentity(from: decoder)
      operationName = try values.decode(String.self, forKey: .operation)
    }

    fileprivate init(id: UUID, target: RuntimeIdentity, operationName: String) {
      self.id = id
      self.target = target
      self.operationName = operationName
    }

    /// Writes identity and discriminator at the existing envelope's top level.
    public func encode(to encoder: any Encoder) throws {
      try target.encode(to: encoder)
      var values = encoder.container(keyedBy: CodingKeys.self)
      try values.encode(id, forKey: .id)
      try values.encode(operationName, forKey: .operation)
    }

    /// Reads a mailbox header before checking its filename and current session.
    public static func decode(_ data: Data) throws -> Self {
      try ControlRequest.validateSize(data)
      let header = try JSONDecoder().decode(Self.self, from: data)
      try ControlRequest.validateMailboxFields(data, headerOnly: true)
      return header
    }
  }

  /// Creates a request whose identity has already been validated.
  public init(id: UUID, target: RuntimeIdentity, operation: Operation) throws {
    var normalized = operation
    switch operation {
    case .push(let payload, _):
      guard try JSONEncoder().encode(payload).count <= 5120 else {
        throw ValidationError.payloadTooLarge
      }
    case .faults(let changes):
      guard !changes.isEmpty, Set(changes.map(Self.faultKey)).count == changes.count else {
        throw ValidationError.invalidFaults
      }
      for change in changes {
        switch change {
        case .reportCallbackDelayMS(let value) where !(0...120_000).contains(value):
          throw ValidationError.invalidFaults
        case .incomingErrorCode(let value) where ![0, 4].contains(value):
          throw ValidationError.invalidFaults
        default: break
        }
      }
      normalized = .faults(
        FaultKey.allCases.compactMap { key in changes.first { Self.faultKey($0) == key } })
    case .call(.tones(_, let digits)):
      guard (1...64).contains(digits.utf8.count),
        digits.utf8.allSatisfy({
          "0123456789*#ABCDabcd".utf8.contains($0)
        })
      else { throw ValidationError.invalidDigits }
    case .call(.merge(let id, let other, _)), .call(.holdAndAccept(let id, let other)),
      .call(.endAndAccept(let id, let other)):
      guard id != other else { throw ValidationError.duplicateCallIDs }
    case .call(.endHeldAndAccept(let id, let active, let held)):
      guard Set([id, active, held]).count == 3 else { throw ValidationError.duplicateCallIDs }
    default: break
    }
    self.id = id
    self.target = target
    self.operation = normalized
  }

  private enum Key: String, CodingKey {
    case id, runID, pid, bundleID, operation, schemaVersion, controlTransport
    case callUUID, activeCallUUID, heldCallUUID, groupWithCallUUID, applicationRequest, held, muted,
      digits, reason
    case faults, payload, mustReport
  }

  private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }

  /// Reads the flat version-one envelope.
  public init(from decoder: any Decoder) throws {
    let header = try Header(from: decoder)
    let values = try decoder.container(keyedBy: Key.self)
    func uuid(_ key: Key = .callUUID) throws -> UUID { try values.decode(UUID.self, forKey: key) }
    func origin() throws -> Origin {
      try values.contains(.applicationRequest)
        && values.decode(Bool.self, forKey: .applicationRequest) ? .application : .system
    }
    var allowed: Set<Key> = [
      .id, .runID, .pid, .bundleID, .operation, .schemaVersion, .controlTransport,
    ]
    let operation: Operation
    switch header.operationName {
    case "status": operation = .status
    case "events": operation = .events
    case "inspect-adapter": operation = .inspectAdapter
    case "reset": operation = .reset
    case "incoming-filter":
      allowed.insert(.reason)
      operation = .incomingFilter(try values.decode(FilterReason.self, forKey: .reason))
    case "faults":
      allowed.insert(.faults)
      let keys = try values.nestedContainer(keyedBy: AnyKey.self, forKey: .faults).allKeys
      guard keys.allSatisfy({ FaultKey(rawValue: $0.stringValue) != nil }) else {
        throw ValidationError.invalidFaults
      }
      let faults = try values.nestedContainer(keyedBy: FaultKey.self, forKey: .faults)
      operation = .faults(
        try FaultKey.allCases.filter { faults.contains($0) }.map { key in
          switch key {
          case .staleAudio: .staleAudio(try faults.decode(Bool.self, forKey: key))
          case .reportCallbackDelayMS:
            .reportCallbackDelayMS(try faults.decode(Int.self, forKey: key))
          case .invalidateDuringHandoff:
            .invalidateDuringHandoff(try faults.decode(Bool.self, forKey: key))
          case .incomingErrorCode: .incomingErrorCode(try faults.decode(Int.self, forKey: key))
          }
        })
    case "push":
      allowed.formUnion([.payload, .mustReport])
      operation = try .push(
        values.decode(PushPayload.self, forKey: .payload),
        mustReport: values.decode(Bool.self, forKey: .mustReport))
    case "answer", "decline", "end":
      allowed.insert(.callUUID)
      let id = try uuid()
      operation = .call(
        header.operationName == "answer"
          ? .answer(id) : header.operationName == "decline" ? .decline(id) : .end(id))
    case "hold":
      allowed.formUnion([.callUUID, .held, .applicationRequest])
      operation = .call(
        try .hold(uuid(), held: values.decode(Bool.self, forKey: .held), origin: origin()))
    case "merge":
      allowed.formUnion([.callUUID, .groupWithCallUUID, .applicationRequest])
      operation = .call(try .merge(uuid(), with: uuid(.groupWithCallUUID), origin: origin()))
    case "unmerge":
      allowed.formUnion([.callUUID, .applicationRequest])
      operation = .call(try .unmerge(uuid(), origin: origin()))
    case "mute":
      allowed.formUnion([.callUUID, .muted])
      operation = .call(try .mute(uuid(), muted: values.decode(Bool.self, forKey: .muted)))
    case "tones":
      allowed.formUnion([.callUUID, .digits])
      operation = .call(try .tones(uuid(), digits: values.decode(String.self, forKey: .digits)))
    case "hold-and-accept", "end-and-accept":
      allowed.formUnion([.callUUID, .activeCallUUID])
      let id = try uuid()
      let active = try uuid(.activeCallUUID)
      operation = .call(
        header.operationName == "hold-and-accept"
          ? .holdAndAccept(id, active: active) : .endAndAccept(id, active: active))
    case "end-held-and-accept":
      allowed.formUnion([.callUUID, .activeCallUUID, .heldCallUUID])
      operation = .call(
        try .endHeldAndAccept(uuid(), active: uuid(.activeCallUUID), held: uuid(.heldCallUUID)))
    default: throw ValidationError.unsupportedOperation(header.operationName)
    }
    let unexpected = Set(values.allKeys).subtracting(allowed)
    guard unexpected.isEmpty else {
      throw ValidationError.unexpectedParameters(unexpected.map(\.rawValue).sorted())
    }
    if values.contains(.schemaVersion), try values.decode(Int.self, forKey: .schemaVersion) != 1 {
      throw ValidationError.unsupportedEnvelope
    }
    if values.contains(.controlTransport) {
      _ = try values.decode(RuntimeSession.ControlTransport.self, forKey: .controlTransport)
    }
    try self.init(id: header.id, target: header.target, operation: operation)
  }

  /// Writes the flat version-one envelope.
  public func encode(to encoder: any Encoder) throws {
    try Header(id: id, target: target, operationName: operation.name).encode(to: encoder)
    var values = encoder.container(keyedBy: Key.self)
    switch operation {
    case .push(let payload, let mustReport):
      try values.encode(payload, forKey: .payload)
      try values.encode(mustReport, forKey: .mustReport)
    case .faults(let changes):
      var faults = values.nestedContainer(keyedBy: FaultKey.self, forKey: .faults)
      for change in changes {
        switch change {
        case .staleAudio(let value): try faults.encode(value, forKey: .staleAudio)
        case .reportCallbackDelayMS(let value):
          try faults.encode(value, forKey: .reportCallbackDelayMS)
        case .invalidateDuringHandoff(let value):
          try faults.encode(value, forKey: .invalidateDuringHandoff)
        case .incomingErrorCode(let value): try faults.encode(value, forKey: .incomingErrorCode)
        }
      }
    case .incomingFilter(let reason): try values.encode(reason, forKey: .reason)
    case .call(let control):
      try values.encode(control.callID, forKey: .callUUID)
      if control.origin == .application { try values.encode(true, forKey: .applicationRequest) }
      switch control {
      case .hold(_, let held, _): try values.encode(held, forKey: .held)
      case .merge(_, let other, _): try values.encode(other, forKey: .groupWithCallUUID)
      case .mute(_, let muted): try values.encode(muted, forKey: .muted)
      case .tones(_, let digits): try values.encode(digits, forKey: .digits)
      case .holdAndAccept(_, let active), .endAndAccept(_, let active):
        try values.encode(active, forKey: .activeCallUUID)
      case .endHeldAndAccept(_, let active, let held):
        try values.encode(active, forKey: .activeCallUUID)
        try values.encode(held, forKey: .heldCallUUID)
      case .answer, .decline, .end, .unmerge: break
      }
    case .status, .events, .inspectAdapter, .reset: break
    }
  }

  /// Decodes a mailbox request, enforcing the file limit and rejecting duplicate fields.
  ///
  /// Use this entry point for mailbox data: a standalone JSONDecoder coalesces duplicate keys
  /// and can round integer tokens. Integer fields require ordinary integer tokens; push
  /// integers outside the signed/unsigned 64-bit range must be represented as strings.
  public static func decode(_ data: Data) throws -> Self {
    try validateSize(data)
    _ = try JSONDecoder().decode(Header.self, from: data)
    try validateMailboxFields(data, headerOnly: false)
    return try JSONDecoder().decode(Self.self, from: data)
  }

  private static func validateSize(_ data: Data) throws {
    guard data.count <= 65_536 else { throw ValidationError.requestTooLarge }
  }

  // Foundation validates JSON syntax first. Observe only the keys and numeric
  // spellings that it otherwise coalesces/rounds before Decodable can see them.
  private static func validateMailboxFields(_ data: Data, headerOnly: Bool) throws {
    let bytes = Array(data)
    let headerKeys: Set<String> = ["id", "runID", "pid", "bundleID", "operation"]
    var objects: [(name: String, keys: Set<String>)] = []
    var objectField = (position: -1, name: "")
    var index = 0
    while index < bytes.count {
      switch bytes[index] {
      case 123: objects.append((objectField.position == index ? objectField.name : "", []))
      case 125: if !objects.isEmpty { objects.removeLast() }
      case 34:
        let start = index
        index += 1
        while index < bytes.count && bytes[index] != 34 {
          index += bytes[index] == 92 ? 2 : 1
        }
        var next = index + 1
        while next < bytes.count && [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
        if index < bytes.count, next < bytes.count, bytes[next] == 58, !objects.isEmpty {
          let key = try JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
          var valueStart = next + 1
          while valueStart < bytes.count && [9, 10, 13, 32].contains(bytes[valueStart]) {
            valueStart += 1
          }
          objectField = (valueStart, key)
          let fresh = objects[objects.count - 1].keys.insert(key).inserted
          if !fresh && (!headerOnly || objects.count == 1 && headerKeys.contains(key)) {
            throw ValidationError.duplicateField(key)
          }
          let integer =
            objects.count == 1 && (key == "pid" || !headerOnly && key == "schemaVersion")
            || !headerOnly && objects.count == 2 && objects[1].name == "faults"
              && ["reportCallbackDelayMS", "incomingErrorCode"].contains(key)
          if integer {
            var end = valueStart
            if end < bytes.count && bytes[end] == 45 { end += 1 }
            while end < bytes.count && (48...57).contains(bytes[end]) { end += 1 }
            guard end < bytes.count, [9, 10, 13, 32, 44, 125].contains(bytes[end]) else {
              throw ValidationError.invalidInteger(key)
            }
          }
        }
      case 45, 48...57:
        var end = index + 1
        while end < bytes.count
          && ((48...57).contains(bytes[end]) || [43, 45, 46, 69, 101].contains(bytes[end]))
        { end += 1 }
        if !headerOnly, objects.count >= 2, objects[1].name == "payload" {
          let token = String(decoding: bytes[index..<end], as: UTF8.self)
          if token.contains(where: { ".eE".contains($0) }) {
            _ = try JSONDecoder().decode(Double.self, from: Data(token.utf8))
          } else if Int64(token) == nil, UInt64(token) == nil {
            throw ValidationError.unsupportedPushInteger
          }
        }
        index = end - 1
      default: break
      }
      index += 1
    }
  }
}
