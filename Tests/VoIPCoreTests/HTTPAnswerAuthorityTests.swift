import Foundation
import Synchronization
import Testing
import VoIPTesting

@testable import VoIPCore

@Suite(.serialized, .timeLimit(.minutes(1)))
struct HTTPAnswerAuthorityTests {
  private static let v1 = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "spec/v1", directoryHint: .isDirectory)

  private static let journeyIDs = [
    "http-answer-allow", "http-answer-refused-elsewhere", "http-answer-timeout-reconcile",
    "http-answer-late-permit-release",
  ]

  @Test(arguments: journeyIDs)
  func sharedHTTPJourney(_ id: String) async throws {
    HTTPAnswerStub.reset()
    let file = Self.v1.appending(path: "journeys/\(id).json")
    let journey = try JSONDecoder().decode(HTTPAnswerJourney.self, from: Data(contentsOf: file))
    #expect(journey.id == id && journey.version == 1)
    try await HTTPAnswerJourneyDriver(configuration: journey.configuration).run(journey)
  }

  @Test func sharedHTTPFixtures() async throws {
    let validRequests: [HTTPRequestFixture] = try readFixtures("valid/requests")
    let invalidRequests: [HTTPRequestFixture] = try readFixtures("invalid/requests")
    for fixture in validRequests + invalidRequests {
      HTTPAnswerStub.reset()
      let context = try request(
        call: #require(fixture.callID), account: #require(fixture.field("accountID")),
        line: #require(fixture.field("lineID")))
      let action = try #require(fixture.field("actionID"))
      let base = fixture.path.hasPrefix("/deployment/v1/") ? "/deployment/" : "/"
      let authority = try authority(path: base, action: action)
      let operation = fixture.operation
      let task = Task { await invoke(operation, authority: authority, context: context) }
      try await HTTPAnswerStub.waitFor(operation)
      try HTTPAnswerStub.reply(.init(operation: operation, status: 409))
      await task.value
      let observation = try #require(HTTPAnswerStub.observations.first)
      #expect(observation.authenticated && observation.hasJSONHeaders)
      #expect((observation.request == fixture) == validRequests.contains(fixture))
    }

    let validReplies: [HTTPResponseFixture] = try readFixtures("valid/responses")
    let invalidReplies: [HTTPResponseFixture] = try readFixtures("invalid/responses")
    let url = try baseURL()
    for fixture in validReplies + invalidReplies {
      let callID = field("callID", in: fixture.body) ?? "call-a"
      let actionID = field("actionID", in: fixture.body) ?? "answer-α"
      let body = HTTPAnswerWire.Body(
        callID: callID, accountID: "account-a", lineID: "personal", actionID: actionID,
        permitID: fixture.operation == .release ? "permit-a" : nil)
      let data = try fixture.data()
      let response = try fixture.response(url)
      if fixture.status == 200, validReplies.contains(fixture) {
        let result = try HTTPAnswerWire.response(
          data, response, operation: fixture.operation, request: body)
        if case .decision(.allow(let permit)) = result, callID == "call-b" {
          #expect(permit.mediaCredentials?.room == "room-b")
          #expect(permit.mediaCredentials?.identity == "participant-b")
        }
      } else {
        let expected: AnswerAuthorityFailure =
          switch fixture.status {
          case 401, 403: .credentialsUnavailable
          case 503, 504: .network
          default: .invalidResponse
          }
        #expect(throws: expected) {
          try HTTPAnswerWire.response(data, response, operation: fixture.operation, request: body)
        }
      }
    }
  }

  @Test(arguments: [
    "http://authority.example.test", "https://user@authority.example.test",
    "https://authority.example.test/?", "https://authority.example.test/#",
    "https://authority.example.test//", "https://authority.example.test/a//b",
    "https://authority.example.test/a/../b", "https://authority.example.test/%2E",
    "https://authority.example.test/folder%2Fother", "https://authority.example.test:0",
  ])
  func rejectsInvalidBaseURL(_ url: String) throws {
    let endpoint = try #require(URL(string: url))
    #expect(throws: HTTPAnswerAuthority.ConfigurationError.invalidEndpoint) {
      try HTTPAnswerAuthority(
        baseURL: endpoint, credential: .init(service: "service", account: "installation"))
    }
  }

  @Test(arguments: ["authority.example.test", "redirect.example.test"])
  func rejectsEveryRedirect(_ host: String) async throws {
    HTTPAnswerStub.reset()
    let authority = try authority()
    let context = try request()
    let task = Task { await authority.claim(context) }
    try await HTTPAnswerStub.waitFor(.claim)
    try HTTPAnswerStub.redirect(
      .claim, to: #require(URL(string: "https://\(host)/v1/answer/claim?redirected=1")))
    #expect(await task.value == .unavailable(.invalidResponse))
    #expect(HTTPAnswerStub.observations.count == 1)
  }

  @Test func unavailableCredentialDoesNotStartAnExchange() async throws {
    HTTPAnswerStub.reset()
    let authority = try authority(load: { nil })
    #expect(await authority.claim(try request()) == .unavailable(.credentialsUnavailable))
    #expect(HTTPAnswerStub.observations.isEmpty)
  }

  @Test func credentialLookupSpendsTheAbsoluteBudget() async throws {
    HTTPAnswerStub.reset()
    let clock = TestClock()
    let start = clock.now
    let durations = Mutex<[Duration]>([])
    let authority = try HTTPAnswerAuthority(
      baseURL: baseURL(),
      readCredential: {
        clock.advance(by: .milliseconds(2400))
        return HTTPAnswerStub.bearer
      },
      send: { _, context in
        durations.withLock { $0.append(context.remaining) }
        throw URLError(.networkConnectionLost)
      })
    let context = try request(now: { start.duration(to: clock.now) })
    #expect(await authority.claim(context) == .unavailable(.network))
    #expect(durations.withLock { $0 } == [.milliseconds(100)])
    #expect(await authority.claim(context) == .unavailable(.network))
    #expect(durations.withLock { $0.count } == 1)
  }

  @Test func transientHTTPFailureIsSentOnceAndReleaseFailureIsReported() async throws {
    HTTPAnswerStub.reset()
    let context = try request()
    let failures = Mutex<[AnswerAuthorityFailure]>([])
    let authority = try authority(onReleaseFailure: { _, _, failure in
      failures.withLock { $0.append(failure) }
    })
    let claim = Task { await authority.claim(context) }
    try await HTTPAnswerStub.waitFor(.claim)
    try HTTPAnswerStub.reply(.init(operation: .claim, status: 503))
    #expect(await claim.value == .unavailable(.network))
    #expect(HTTPAnswerStub.observations.map(\.operation) == [.claim])

    let release = Task { await authority.release(AnswerPermit(id: "permit-a"), for: context) }
    try await HTTPAnswerStub.waitFor(.release)
    try HTTPAnswerStub.reply(.init(operation: .release, status: 401))
    await release.value
    #expect(failures.withLock { $0 } == [.credentialsUnavailable])
    #expect(HTTPAnswerStub.observations.map(\.operation) == [.claim, .release])
  }

  @Test func sessionCancelsTransportAtTheMonotonicDeadline() async throws {
    HTTPAnswerStub.reset()
    let clock = TestClock()
    let start = clock.now
    let context = try request(
      now: { start.duration(to: clock.now) },
      sleep: { try await clock.sleep(until: start.advanced(by: $0)) })
    let authority = try authority()
    let task = Task { await authority.claim(context) }
    try await HTTPAnswerStub.waitFor(.claim)
    clock.advance(by: .milliseconds(2500))
    #expect(await task.value == .unavailable(.network))
    #expect(HTTPAnswerStub.observations.map(\.operation) == [.claim])
  }

  @Test func rejectsAlternateUnicodeEncodings() throws {
    let fixture = serverPermit(.claim)
    let text = try #require(String(data: fixture.data(), encoding: .utf8))
    let body = HTTPAnswerWire.Body(
      callID: "call-a", accountID: "account-a", lineID: "personal", actionID: "answer-α",
      permitID: nil)
    let response = try fixture.response(baseURL())
    for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
      let data = try #require(text.data(using: encoding))
      #expect(throws: AnswerAuthorityFailure.invalidResponse) {
        try HTTPAnswerWire.response(data, response, operation: .claim, request: body)
      }
    }
  }

  @Test(arguments: [true, false])
  @VoIPActor func matchingPermitsReleaseOnce(_ reconcileBeforeExpiry: Bool) async throws {
    HTTPAnswerStub.reset()
    let authority = try authority(allowLateReply: true)
    let rig = try HTTPAnswerRig(authority: authority, media: FakeMedia())
    defer { rig.engine.close() }
    let claim = try rig.inviteAndAnswer()
    try await HTTPAnswerStub.waitFor(.claim)
    rig.clock.advance(by: .milliseconds(2500))
    await rig.engine.synchronize()
    let reconciliation = try #require(rig.engine.answerTask(rig.callID, reconciling: true))
    try await HTTPAnswerStub.waitFor(.reconcile)
    if reconcileBeforeExpiry {
      try HTTPAnswerStub.reply(serverPermit(.claim))
      await claim.value
      #expect(HTTPAnswerStub.observations.map(\.operation) == [.claim, .reconcile])
      try HTTPAnswerStub.reply(serverPermit(.reconcile))
      await reconciliation.value
      await rig.engine.synchronize()
      #expect(rig.status == .connecting)
      #expect(rig.framework.records.count { $0 == .fulfill(a1) } == 1)
      _ = try rig.engine.end(rig.callID)
      try await HTTPAnswerStub.waitFor(.release)
      try HTTPAnswerStub.reply(releaseAcknowledgment)
    } else {
      rig.clock.advance(by: .milliseconds(500))
      await rig.engine.synchronize()
      try HTTPAnswerStub.reply(serverPermit(.reconcile))
      try await HTTPAnswerStub.waitFor(.release)
      try HTTPAnswerStub.reply(releaseAcknowledgment)
      await reconciliation.value
      try HTTPAnswerStub.reply(serverPermit(.claim))
      await claim.value
      #expect(rig.status == .ended(.failed(.answerAuthorization(.claimTimedOut))))
      #expect(rig.framework.records.count { $0 == .fail(a1) } == 1)
    }
    #expect(HTTPAnswerStub.observations.map(\.operation) == [.claim, .reconcile, .release])
  }

  @Test(arguments: [false, true])
  @VoIPActor func mediaCredentialsStayBehindTheNativePreparationGate(_ expired: Bool) async throws {
    HTTPAnswerStub.reset()
    let authority = try authority()
    let media = HTTPAnswerMedia()
    media.fake.preparation = .wait
    let rig = try HTTPAnswerRig(authority: authority, media: media)
    defer { rig.engine.close() }
    let task = try rig.inviteAndAnswer()
    try await HTTPAnswerStub.waitFor(.claim)
    #expect(media.fake.records.isEmpty)
    let expiry = Int(rig.wallNow().timeIntervalSince1970) + (expired ? 0 : 30)
    try HTTPAnswerStub.reply(
      serverPermit(
        .claim,
        media: [
          "provider": "livekit", "url": "wss://media.example.test", "room": "room-a",
          "identity": "installation-a", "token": "synthetic-media-token",
          "expiresAt": .number(Double(expiry)),
        ]))
    if expired {
      try await HTTPAnswerStub.waitFor(.release)
      try HTTPAnswerStub.reply(releaseAcknowledgment)
      await task.value
      #expect(media.fake.records.isEmpty)
      #expect(rig.status == .ended(.failed(.answerAuthorization(.unavailable(.invalidResponse)))))
      #expect(rig.framework.records.count { $0 == .fail(a1) } == 1)
      return
    }
    await task.value
    let limit = ContinuousClock.now + .seconds(5)
    while !media.fake.waitingCalls.contains(rig.callID), ContinuousClock.now < limit {
      try await Task.sleep(for: .milliseconds(2))
    }
    try #require(media.fake.waitingCalls == [rig.callID])
    #expect(media.room == "room-a" && media.identity == "installation-a")
    #expect(media.ordinaryPreparations == 0)
    rig.framework.send(.audioActivated)
    #expect(rig.status == .ringing && !rig.framework.records.contains(.fulfill(a1)))
    #expect(!media.fake.records.contains(.activate))
    media.fake.finishPreparing(rig.callID, succeeded: true)
    await rig.engine.synchronize()
    #expect(rig.status == .connecting)
    #expect(rig.framework.records.count { $0 == .fulfill(a1) } == 1)
    #expect(media.fake.records.contains(.activate))
    _ = try rig.engine.end(rig.callID)
    try await HTTPAnswerStub.waitFor(.release)
    try HTTPAnswerStub.reply(releaseAcknowledgment)
  }

  private func serverPermit(
    _ operation: HTTPAnswerWire.Operation, media: JSONValue? = nil
  ) -> HTTPResponseFixture {
    var body: [String: JSONValue] = [
      "version": 1, "callID": "call-a", "actionID": "answer-α", "kind": "allow",
      "permit": ["id": "permit-a", "expiresAt": "2026-11-18T00:00:30.000Z"],
    ]
    body["media"] = media
    return HTTPResponseFixture(
      operation: operation, status: 200, idempotencyKey: "v1.YW5zd2VyLc6x", body: .object(body))
  }

  private var releaseAcknowledgment: HTTPResponseFixture {
    HTTPResponseFixture(
      operation: .release, status: 200, idempotencyKey: "v1.YW5zd2VyLc6x",
      body: ["version": 1, "callID": "call-a", "actionID": "answer-α", "kind": "released"])
  }

  private func readFixtures<Value: Decodable>(_ name: String) throws -> Value {
    let url = Self.v1.appending(path: "http-authority/fixtures/\(name).json")
    return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
  }

  private func field(_ key: String, in body: JSONValue?) -> String? {
    if case .object(let fields) = body, case .string(let value) = fields[key] { value } else { nil }
  }

  private func baseURL(_ path: String = "") throws -> URL {
    try #require(URL(string: "https://authority.example.test\(path)"))
  }

  private func authority(
    path: String = "", action: String = "answer-α", allowLateReply: Bool = false,
    load: @escaping @Sendable () async -> String? = { HTTPAnswerStub.bearer },
    onReleaseFailure: @escaping HTTPAnswerAuthority.ReleaseFailure = { _, _, _ in }
  ) throws -> HTTPAnswerAuthority {
    try HTTPAnswerAuthority(
      baseURL: baseURL(path), readCredential: load, actionIdentifier: { _ in action },
      send: { request, context in
        if allowLateReply {
          let delivery = Task {
            try await HTTPAnswerSession.exchange(
              request, remaining: .seconds(10), protocols: [HTTPAnswerStub.self])
          }
          return try await delivery.value
        }
        return try await HTTPAnswerSession.exchange(
          request, context: context, protocols: [HTTPAnswerStub.self])
      },
      onReleaseFailure: onReleaseFailure)
  }

  private func request(
    call: String = "call-a", account: String = "account-a", line: String = "personal",
    now: @escaping @Sendable () -> Duration = { .zero },
    sleep: (@Sendable (Duration) async throws -> Void)? = nil
  ) throws -> AnswerRequest {
    let call = Call(
      id: CallID(rawValue: call), isIncoming: true, parties: [alice], status: .ringing,
      answerScope: .init(accountID: account, lineID: line))
    return AnswerRequest(
      call: call, actionID: a1, deadline: .milliseconds(2500), now: now, sleep: sleep)
  }

  private func invoke(
    _ operation: HTTPAnswerWire.Operation, authority: HTTPAnswerAuthority, context: AnswerRequest
  ) async {
    switch operation {
    case .claim: _ = await authority.claim(context)
    case .reconcile: _ = await authority.reconcile(context)
    case .release: await authority.release(AnswerPermit(id: "permit-a"), for: context)
    }
  }
}

@VoIPActor
private final class HTTPAnswerRig {
  let clock = TestClock()
  let framework = FakeCallingFramework()
  let push = FakePushSource()
  let callID = CallID(rawValue: "call-a")
  let wallNow: @Sendable () -> Date
  let engine: SpecEngine

  init(authority: HTTPAnswerAuthority, media: any CallMedia) throws {
    wallNow = try httpTestWallClock(clock)
    engine = SpecEngine(
      framework: framework, media: media, push: push, configuration: .init(),
      clock: clock, authority: authority, wallNow: wallNow, observe: { _ in })
  }

  func inviteAndAnswer() throws -> Task<Void, Never> {
    let call = IncomingCall(
      id: callID, parties: [alice], answerScope: .init(accountID: "account-a", lineID: "personal"))
    push.deliver(.incoming(call, eventID: EventID(rawValue: "invite")))
    framework.send(.performAnswer(a1, callID, remaining: .seconds(30)))
    return try #require(engine.answerTask(callID))
  }

  var status: CallStatus? { engine.calls.first { $0.id == callID }?.status }
}

@VoIPActor
private final class HTTPAnswerMedia: CallMedia {
  let fake = FakeMedia()
  private(set) var room: String?
  private(set) var identity: String?
  private(set) var ordinaryPreparations = 0

  func prepare(_ call: Call) async throws { ordinaryPreparations += 1 }

  func prepare(_ call: Call, answerCredentials: AnswerMediaCredentials) async throws {
    room = answerCredentials.room
    identity = answerCredentials.identity
    try await fake.prepare(call)
  }

  func activate() { fake.activate() }
  func deactivate() { fake.deactivate() }
  func release(_ call: Call) { fake.release(call) }
}
