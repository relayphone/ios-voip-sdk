import Foundation
import Synchronization
import Testing

@testable import VoIPCore

struct HTTPRequestFixture: Decodable, Equatable, Sendable {
  let kind: String
  let operation: HTTPAnswerWire.Operation
  let method: String
  let path: String
  let idempotencyKey: String
  let body: JSONValue

  var callID: String? { field("callID") }

  func field(_ key: String) -> String? {
    if case .object(let fields) = body, case .string(let value) = fields[key] { value } else { nil }
  }
}

struct HTTPResponseFixture: Decodable, Equatable, Sendable {
  let kind: String
  let operation: HTTPAnswerWire.Operation
  let status: Int
  let idempotencyKey: String?
  let body: JSONValue?

  init(
    operation: HTTPAnswerWire.Operation, status: Int, idempotencyKey: String? = nil,
    body: JSONValue? = nil
  ) {
    kind = "response"
    self.operation = operation
    self.status = status
    self.idempotencyKey = idempotencyKey
    self.body = body
  }

  func data() throws -> Data { try body.map { try JSONEncoder().encode($0) } ?? Data() }

  func response(_ url: URL) throws -> HTTPURLResponse {
    var headers = ["Content-Type": "application/json; charset=utf-8"]
    headers["Idempotency-Key"] = idempotencyKey
    return try #require(
      HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
  }
}

/// Intercepts every URL to keep failed assertions and attempted redirects off the network.
final class HTTPAnswerStub: URLProtocol, @unchecked Sendable {
  static let bearer = "synthetic-test-credential"

  private struct State {
    var observations: [Observation] = []
    var pending: [HTTPAnswerWire.Operation: HTTPAnswerStub] = [:]
    var completed: [HTTPResponseFixture] = []
  }

  struct Observation: Sendable {
    let operation: HTTPAnswerWire.Operation?
    let request: HTTPRequestFixture?
    let authenticated: Bool
    let hasJSONHeaders: Bool
    let host: String?
  }

  private static let state = Mutex(State())
  static var observations: [Observation] { state.withLock { $0.observations } }

  static func reset() { state.withLock { $0 = State() } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let operation = request.url.flatMap { HTTPAnswerWire.Operation(rawValue: $0.lastPathComponent) }
    let observed: HTTPRequestFixture? =
      if let operation, let url = request.url, let method = request.httpMethod,
        let key = request.value(forHTTPHeaderField: "Idempotency-Key"),
        let payload = loadBody(),
        let body = try? JSONDecoder().decode(JSONValue.self, from: payload)
      {
        HTTPRequestFixture(
          kind: "request", operation: operation, method: method, path: url.path,
          idempotencyKey: key, body: body)
      } else { nil }
    Self.state.withLock { state in
      state.observations.append(
        .init(
          operation: operation, request: observed,
          authenticated: request.value(forHTTPHeaderField: "Authorization")
            == "Bearer \(Self.bearer)",
          hasJSONHeaders: request.value(forHTTPHeaderField: "Content-Type") == "application/json"
            && request.value(forHTTPHeaderField: "Accept") == "application/json",
          host: request.url?.host))
      if let operation { state.pending[operation] = self }
    }
    if operation == nil { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) }
  }

  override func stopLoading() {
    Self.state.withLock { state in
      state.pending = state.pending.filter { $0.value !== self }
    }
  }

  static func finishIfPending(_ operation: HTTPAnswerWire.Operation) throws {
    if state.withLock({ $0.pending[operation] != nil }) {
      try reply(.init(operation: operation, status: 409))
    }
  }

  static func waitFor(_ operation: HTTPAnswerWire.Operation) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !observations.contains(where: { $0.operation == operation }) {
      guard ContinuousClock.now < deadline else { throw StubError.missingRequest }
      try await Task.sleep(for: .milliseconds(2))
    }
  }

  @discardableResult
  static func reply(_ fixture: HTTPResponseFixture) throws -> Bool {
    let exchange = state.withLock { state in
      let exchange = state.pending.removeValue(forKey: fixture.operation)
      if exchange != nil { state.completed.append(fixture) }
      return exchange
    }
    guard let exchange else {
      guard state.withLock({ $0.completed.contains(fixture) }) else {
        throw StubError.missingRequest
      }
      // A repeated transmission for a completed URLSession task cannot complete it again.
      return false
    }
    let url = try #require(exchange.request.url)
    let response = try fixture.response(url)
    let data = try fixture.data()
    exchange.client?.urlProtocol(exchange, didReceive: response, cacheStoragePolicy: .notAllowed)
    exchange.client?.urlProtocol(exchange, didLoad: data)
    exchange.client?.urlProtocolDidFinishLoading(exchange)
    return true
  }

  static func redirect(
    _ operation: HTTPAnswerWire.Operation, to destination: URL
  ) throws {
    let exchange = try #require(state.withLock { $0.pending.removeValue(forKey: operation) })
    let origin = try #require(exchange.request.url)
    let response = try #require(
      HTTPURLResponse(
        url: origin, statusCode: 307, httpVersion: "HTTP/1.1",
        headerFields: ["Location": destination.absoluteString]))
    var forwarded = URLRequest(url: destination)
    forwarded.httpMethod = "POST"
    forwarded.setValue(
      exchange.request.value(forHTTPHeaderField: "Authorization"),
      forHTTPHeaderField: "Authorization")
    exchange.client?.urlProtocol(exchange, wasRedirectedTo: forwarded, redirectResponse: response)
  }

  private func loadBody() -> Data? {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var payload = Data()
    var buffer = [UInt8](repeating: 0, count: 512)
    while true {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count < 0 { return nil }
      if count == 0 { return payload }
      payload.append(contentsOf: buffer.prefix(count))
    }
  }

  enum StubError: Error { case missingRequest }
}
