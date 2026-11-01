import Foundation

/// The error with which the calling framework refused something, by its domain and code.
///
/// LiveCommunicationKit passes on the errors of the system's call service, which keep CallKit's
/// error domains and codes. A refused action usually wraps an error in
/// `com.apple.CallKit.error.requesttransaction`, whose codes are those of CallKit's
/// `CXErrorCodeRequestTransactionError`, such as 1 when the app isn't entitled to the request or
/// 7 when it has as many calls as it may. The SDK keeps the error and the errors it wraps, so that
/// the app and its logs can say why the system refused:
///
/// ```swift
/// do {
///   try await client.request(.join(id))
/// } catch .refused(let error?) {
///   logger.error("The system refused the join: \(error)")
/// } catch {
///   logger.error("Couldn't join: \(error)")
/// }
/// ```
public struct FrameworkError: Hashable, Sendable, CustomStringConvertible {
  /// The error's domain.
  public var domain: String

  /// The error's code in its domain.
  public var code: Int

  /// The errors that this error wraps, such as the call service's error inside
  /// LiveCommunicationKit's.
  public var underlyingErrors: [FrameworkError]

  /// How many levels of wrapped errors the SDK keeps.
  static let maximumDepth = 4

  /// Creates the description of an error.
  ///
  /// - Parameters:
  ///   - domain: The error's domain.
  ///   - code: The error's code in its domain.
  ///   - underlyingErrors: The errors that the error wraps.
  public init(domain: String, code: Int, underlyingErrors: [FrameworkError] = []) {
    self.domain = domain
    self.code = code
    self.underlyingErrors = underlyingErrors
  }

  /// Describes an error that the calling framework threw, with the errors it wraps.
  ///
  /// Calling-framework adapters use it. It keeps the domain and code of the error and of the
  /// errors that its `NSError` wraps, a few levels deep.
  ///
  /// - Parameter error: The calling framework's error.
  public init(_ error: any Error) {
    self.init(error as NSError, depth: 1)
  }

  private init(_ error: NSError, depth: Int) {
    let underlying =
      depth < Self.maximumDepth
      ? error.underlyingErrors.map { FrameworkError($0 as NSError, depth: depth + 1) } : []
    self.init(domain: error.domain, code: error.code, underlyingErrors: underlying)
  }

  /// The domain and code, followed by those of the wrapped errors in parentheses, such as
  /// `com.apple.CallKit.error.requesttransaction 7`, or `A 2 (B 1)` for an error in domain `A`
  /// that wraps one in domain `B`.
  public var description: String {
    let own = "\(domain) \(code)"
    guard !underlyingErrors.isEmpty else { return own }
    return "\(own) (\(underlyingErrors.map(\.description).joined(separator: ", ")))"
  }
}
