/// A JSON value: null, a Boolean, a number, a string, an array or an object.
///
/// A call's ``Call/metadata`` holds the JSON values that its VoIP push, ``IncomingCall`` or
/// ``OutgoingCall`` carried. Write values with literals, and `.null` for JSON's `null`:
///
/// ```swift
/// let metadata: [String: JSONValue] = [
///   "room": "room-\(roomNumber)",
///   "attempt": 2,
///   "recorded": false,
///   "route": ["region": "eu", "hops": ["sip", "media"], "fallback": .null],
/// ]
/// ```
///
/// Read them by matching the cases:
///
/// ```swift
/// if case .string(let room)? = call.metadata["room"] {
///   try await server.join(room: room)
/// }
/// ```
///
/// A number is a `Double`, as in JavaScript, so an integer beyond ±2^53 loses precision. Send
/// larger integers, such as 64-bit identifiers, as strings.
public enum JSONValue: Hashable, Sendable {
  /// JSON's `null`.
  case null
  /// A Boolean, which JSON writes as `true` or `false`.
  case bool(Bool)
  /// A number. JSON has no NaN or infinity, so encoding either throws.
  case number(Double)
  /// A string.
  case string(String)
  /// An ordered list of values.
  case array([JSONValue])
  /// Values keyed by unique strings, in no particular order.
  case object([String: JSONValue])
}

extension JSONValue: Codable {
  /// Creates a value by decoding it from the decoder's single value.
  ///
  /// - Parameter decoder: The decoder to read from.
  /// - Throws: `DecodingError` when the decoder's value isn't a JSON value.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  /// Encodes the value into the encoder as a single value.
  ///
  /// - Parameter encoder: The encoder to write to.
  /// - Throws: `EncodingError` when the encoder can't write the value, such as a NaN or infinite
  ///   number to a `JSONEncoder` without a non-conforming float strategy.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

extension JSONValue: ExpressibleByBooleanLiteral {
  /// Creates a Boolean from a literal.
  public init(booleanLiteral value: Bool) {
    self = .bool(value)
  }
}

extension JSONValue: ExpressibleByIntegerLiteral {
  /// Creates a number from an integer literal.
  public init(integerLiteral value: Int) {
    self = .number(Double(value))
  }
}

extension JSONValue: ExpressibleByFloatLiteral {
  /// Creates a number from a floating-point literal.
  public init(floatLiteral value: Double) {
    self = .number(value)
  }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
  /// Creates a string from a literal, which may interpolate values.
  public init(stringLiteral value: String) {
    self = .string(value)
  }
}

extension JSONValue: ExpressibleByArrayLiteral {
  /// Creates an array from a literal.
  public init(arrayLiteral elements: JSONValue...) {
    self = .array(elements)
  }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
  /// Creates an object from a literal, whose keys must be unique, as in a dictionary literal.
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(uniqueKeysWithValues: elements))
  }
}
