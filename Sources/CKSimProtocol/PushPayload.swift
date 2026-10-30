import Foundation

/// Arbitrary application JSON carried only by the simulator push-injection control.
public struct PushPayload: Codable, Equatable, Sendable {
  /// The application's top-level JSON object.
  public let fields: [String: Value]
  /// Creates an application payload; the request enforces its encoded byte limit.
  public init(fields: [String: Value]) { self.fields = fields }

  /// A JSON value, preserving integer precision before bridging to PushKit.
  public indirect enum Value: Codable, Equatable, Sendable {
    /// A JSON null.
    case null
    /// A JSON boolean, distinct from numeric zero and one.
    case boolean(Bool)
    /// A signed integer represented without floating-point conversion.
    case integer(Int64)
    /// An unsigned integer represented without floating-point conversion.
    case unsigned(UInt64)
    /// A finite floating-point JSON number.
    case number(Double)
    /// A JSON string.
    case string(String)
    /// An ordered JSON array.
    case array([Value])
    /// A nested JSON object.
    case object([String: Value])

    /// Decodes application JSON without conflating booleans and numbers.
    public init(from decoder: any Decoder) throws {
      let value = try decoder.singleValueContainer()
      if value.decodeNil() {
        self = .null
      } else if let decoded = try? value.decode(Bool.self) {
        self = .boolean(decoded)
      } else if let decoded = try? value.decode(Int64.self) {
        self = .integer(decoded)
      } else if let decoded = try? value.decode(UInt64.self) {
        self = .unsigned(decoded)
      } else if let decoded = try? value.decode(Double.self) {
        self = .number(decoded)
      } else if let decoded = try? value.decode(String.self) {
        self = .string(decoded)
      } else if let decoded = try? value.decode([Value].self) {
        self = .array(decoded)
      } else {
        self = .object(try value.decode([String: Value].self))
      }
    }

    /// Encodes the application value as ordinary JSON.
    public func encode(to encoder: any Encoder) throws {
      var value = encoder.singleValueContainer()
      switch self {
      case .null: try value.encodeNil()
      case .boolean(let decoded): try value.encode(decoded)
      case .integer(let decoded): try value.encode(decoded)
      case .unsigned(let decoded): try value.encode(decoded)
      case .number(let decoded): try value.encode(decoded)
      case .string(let decoded): try value.encode(decoded)
      case .array(let decoded): try value.encode(decoded)
      case .object(let decoded): try value.encode(decoded)
      }
    }

    /// Compares JSON numbers by exact value across their supported representations.
    public static func == (lhs: Self, rhs: Self) -> Bool {
      switch (lhs, rhs) {
      case (.null, .null): true
      case (.boolean(let a), .boolean(let b)): a == b
      case (.integer(let a), .integer(let b)): a == b
      case (.unsigned(let a), .unsigned(let b)): a == b
      case (.number(let a), .number(let b)): a == b
      case (.integer(let a), .unsigned(let b)), (.unsigned(let b), .integer(let a)):
        UInt64(exactly: a) == b
      case (.integer(let a), .number(let b)), (.number(let b), .integer(let a)):
        Int64(exactly: b) == a
      case (.unsigned(let a), .number(let b)), (.number(let b), .unsigned(let a)):
        UInt64(exactly: b) == a
      case (.string(let a), .string(let b)): a == b
      case (.array(let a), .array(let b)): a == b
      case (.object(let a), .object(let b)): a == b
      default: false
      }
    }
  }

  /// Requires an object at the PushKit application-payload boundary.
  public init(from decoder: any Decoder) throws {
    fields = try decoder.singleValueContainer().decode([String: Value].self)
  }

  /// Writes only the application object, without adding a protocol wrapper.
  public func encode(to encoder: any Encoder) throws {
    var value = encoder.singleValueContainer()
    try value.encode(fields)
  }
}
