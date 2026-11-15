#if os(macOS) || (os(iOS) && targetEnvironment(simulator))
  import Foundation

  // JSONSerialization's default options produce immutable JSON containers. This box crosses
  // the delivery task boundary but never mutates or exposes mutable application objects.
  final class PreparedPushPayload: @unchecked Sendable {
    let dictionary: [String: Any]

    enum ValidationError: Error, Equatable { case invalid(String) }

    init(_ payload: some Encodable) throws {
      let bytes = try JSONEncoder().encode(payload)
      guard let dictionary = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
        throw ValidationError.invalid("payload object required")
      }
      self.dictionary = dictionary
    }
  }
#endif
