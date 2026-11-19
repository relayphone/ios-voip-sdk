public import Foundation
import LocalAuthentication
import Security
import Synchronization

/// Native Answer authority for the version 1 HTTPS protocol.
///
/// Start the client with this authority and set ``IncomingCall/answerScope`` on incoming calls.
/// Native onboarding provisions and rotates the installation credential in Keychain.
public struct HTTPAnswerAuthority: AnswerAuthority {
  /// The location of a generic password containing the UTF-8 bearer token.
  public struct CredentialReference: Sendable {
    /// The Keychain service.
    public let service: String
    /// The Keychain account naming the installation's credential.
    public let account: String
    /// The optional Keychain access group shared with native onboarding.
    public let accessGroup: String?

    /// Identifies a credential without transferring its value.
    public init(service: String, account: String, accessGroup: String? = nil) {
      self.service = service
      self.account = account
      self.accessGroup = accessGroup
    }

    @concurrent
    fileprivate func read() async -> String? {
      let context = LAContext()
      context.interactionNotAllowed = true
      var query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
        kSecUseDataProtectionKeychain: true, kSecUseAuthenticationContext: context,
        kSecMatchLimit: kSecMatchLimitOne, kSecReturnData: true,
      ]
      if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
      var item: CFTypeRef?
      guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
        let data = item as? Data
      else { return nil }
      return String(data: data, encoding: .utf8)
    }
  }

  /// Why an HTTP authority could not be configured.
  public enum ConfigurationError: Error, Sendable {
    /// The base URL must be an HTTPS origin with an optional deployment path prefix.
    case invalidEndpoint
  }

  /// Reports a failed cleanup without changing the call's terminal reason.
  public typealias ReleaseFailure =
    @Sendable (CallID, ActionID, AnswerAuthorityFailure) -> Void

  typealias Transport = @Sendable (URLRequest, AnswerRequest) async throws -> (Data, URLResponse)

  private let endpoint: HTTPAnswerWire.Endpoint
  private let readCredential: @Sendable () async -> String?
  private let send: Transport
  private let actionIdentifier: @Sendable (ActionID) -> String
  private let onReleaseFailure: ReleaseFailure

  /// Creates an authority with platform TLS and a Keychain-held credential.
  ///
  /// The optional deployment path uses ASCII letters, digits, `-`, `_`, `.` and `~` in
  /// each segment. The URL may also end in a slash. Release failures can be observed through
  /// `onReleaseFailure`, which receives only identifiers and the typed failure.
  public init(
    baseURL: URL, credential: CredentialReference,
    onReleaseFailure: @escaping ReleaseFailure = { _, _, _ in }
  ) throws(ConfigurationError) {
    try self.init(
      baseURL: baseURL, readCredential: { await credential.read() },
      actionIdentifier: { $0.rawValue.uuidString },
      send: { try await HTTPAnswerSession.exchange($0, context: $1) },
      onReleaseFailure: onReleaseFailure)
  }

  init(
    baseURL: URL, readCredential: @escaping @Sendable () async -> String?,
    actionIdentifier: @escaping @Sendable (ActionID) -> String = { $0.rawValue.uuidString },
    send: @escaping Transport, onReleaseFailure: @escaping ReleaseFailure = { _, _, _ in }
  ) throws(ConfigurationError) {
    guard let endpoint = HTTPAnswerWire.Endpoint(baseURL) else { throw .invalidEndpoint }
    self.endpoint = endpoint
    self.readCredential = readCredential
    self.actionIdentifier = actionIdentifier
    self.send = send
    self.onReleaseFailure = onReleaseFailure
  }

  /// Claims the original native Answer once.
  public func claim(_ request: AnswerRequest) async -> AnswerDecision {
    await decision(.claim, request) ?? .unavailable(.invalidResponse)
  }

  /// Reads the decision for the original Answer receipt.
  public func reconcile(_ request: AnswerRequest) async -> AnswerDecision? {
    await decision(.reconcile, request)
  }

  /// Relinquishes the permit; reports cleanup failures independently of Answer settlement.
  public func release(_ permit: AnswerPermit, for request: AnswerRequest) async {
    do {
      _ = try await exchange(.release, request, permitID: permit.id)
    } catch {
      onReleaseFailure(request.call.id, request.actionID, error)
    }
  }

  private func decision(
    _ operation: HTTPAnswerWire.Operation, _ request: AnswerRequest
  ) async -> AnswerDecision? {
    do {
      switch try await exchange(operation, request) {
      case .decision(let decision): return decision
      case .unknown, .released: return nil
      }
    } catch {
      return .unavailable(error)
    }
  }

  private func exchange(
    _ operation: HTTPAnswerWire.Operation, _ request: AnswerRequest, permitID: String? = nil
  ) async throws(AnswerAuthorityFailure) -> HTTPAnswerWire.Resolution {
    guard !Task.isCancelled, request.remaining > .zero else { throw .network }
    guard let scope = request.call.answerScope, let url = endpoint.url(operation) else {
      throw .invalidResponse
    }
    let body = HTTPAnswerWire.Body(
      callID: request.call.id.rawValue, accountID: scope.accountID, lineID: scope.lineID,
      actionID: actionIdentifier(request.actionID), permitID: permitID)
    guard body.isValid, let data = try? JSONEncoder().encode(body) else {
      throw .invalidResponse
    }

    // Resolve the reference on each request so native rotation does not require restarting.
    guard let bearer = await readCredential(),
      bearer.wholeMatch(of: #/[A-Za-z0-9._~+\/-]+=*/#) != nil
    else { throw .credentialsUnavailable }

    var outbound = URLRequest(url: url)
    outbound.httpMethod = "POST"
    outbound.setValue("application/json", forHTTPHeaderField: "Content-Type")
    outbound.setValue("application/json", forHTTPHeaderField: "Accept")
    outbound.setValue(body.key, forHTTPHeaderField: "Idempotency-Key")
    outbound.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    outbound.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
    // A single-use body prevents URLSession from replaying the action after a transport failure.
    outbound.httpBodyStream = InputStream(data: data)
    guard !Task.isCancelled, request.remaining > .zero else { throw .network }

    let payload: Data
    let response: URLResponse
    do {
      (payload, response) = try await send(outbound, request)
    } catch let error as AnswerAuthorityFailure {
      throw error
    } catch let error as URLError {
      switch error.code {
      case .userAuthenticationRequired: throw .credentialsUnavailable
      case .httpTooManyRedirects, .redirectToNonExistentLocation,
        .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed,
        .serverCertificateHasBadDate, .serverCertificateUntrusted,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
        .clientCertificateRejected, .clientCertificateRequired:
        throw .invalidResponse
      default: throw .network
      }
    } catch {
      throw .network
    }
    // Return late grants for the engine to release. The engine checks the same monotonic deadline
    // before accepting a claim or reconciliation. Release has its own bounded cleanup deadline.
    let result = try HTTPAnswerWire.response(payload, response, operation: operation, request: body)
    if operation == .release, request.remaining == .zero { throw .network }
    return result
  }
}

enum HTTPAnswerSession {
  static func exchange(
    _ request: URLRequest, context: AnswerRequest, protocols: [AnyClass]? = nil
  ) async throws -> (Data, URLResponse) {
    let outbound = Task {
      try Task.checkCancellation()
      let remaining = context.remaining
      guard remaining > .zero else { throw URLError(.timedOut) }
      return try await exchange(request, remaining: remaining, protocols: protocols)
    }
    let timeout = context.sleep.map { sleep in
      Task {
        do { try await sleep(context.deadline) } catch { return }
        outbound.cancel()
      }
    }
    defer { timeout?.cancel() }
    return try await withTaskCancellationHandler {
      try await outbound.value
    } onCancel: {
      outbound.cancel()
    }
  }

  static func exchange(
    _ request: URLRequest, remaining: Duration, protocols: [AnyClass]? = nil
  ) async throws -> (Data, URLResponse) {
    let time = remaining.components
    let seconds = Double(time.seconds) + Double(time.attoseconds) / 1e18
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.waitsForConnectivity = false
    configuration.timeoutIntervalForRequest = seconds
    configuration.timeoutIntervalForResource = seconds
    if let protocols { configuration.protocolClasses = protocols }
    let delegate = Delegate()
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    var request = request
    request.timeoutInterval = seconds
    do {
      return try await session.data(for: request)
    } catch {
      if delegate.redirectRefused.withLock({ $0 }) { throw AnswerAuthorityFailure.invalidResponse }
      throw error
    }
  }

  private final class Delegate: NSObject, URLSessionTaskDelegate {
    let redirectRefused = Mutex(false)

    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
      redirectRefused.withLock { $0 = true }
      completionHandler(nil)
      task.cancel()
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
      completionHandler:
        @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
      let disposition: URLSession.AuthChallengeDisposition =
        challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
        ? .performDefaultHandling : .rejectProtectionSpace
      completionHandler(disposition, nil)
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void
    ) {
      completionHandler(nil)
    }
  }
}
