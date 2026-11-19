import Foundation
import Testing
import VoIPTesting

@testable import VoIPCore

struct HTTPAnswerJourney: Decodable {
  let version: Int
  let id: String
  let configuration: SpecJourney.Configuration
  let steps: [Step]

  enum Step: Decodable {
    case standard(SpecJourney.Step)
    case install(callID: SpecV0.ID, actionID: SpecV0.ID, credentialRef: String)
    case reply(HTTPResponseFixture)
    case requests(callID: SpecV0.ID, [HTTPRequestFixture])

    private struct Payload: Decodable {
      let kind: String
      let callID: SpecV0.ID?
      let actionID: SpecV0.ID?
      let credentialRef: String?
      let response: HTTPResponseFixture?
      let requests: [HTTPRequestFixture]?
    }

    init(from decoder: any Decoder) throws {
      let outer = try SpecV0.Object(decoder)
      let input: Payload? = try outer.optional("input")
      let expectation: Payload? = try outer.optional("expectation")
      switch (input?.kind, expectation?.kind) {
      case ("useHTTPAuthority", nil):
        self = .install(
          callID: try #require(input?.callID), actionID: try #require(input?.actionID),
          credentialRef: try #require(input?.credentialRef))
      case ("httpReply", nil):
        self = .reply(try #require(input?.response))
      case (nil, "httpRequests"):
        self = .requests(
          callID: try #require(expectation?.callID), try #require(expectation?.requests))
      default:
        self = .standard(try SpecJourney.Step(from: decoder))
      }
    }
  }
}

/// Advances the engine's real timers and drives its ports without platform calling or audio.
@VoIPActor
final class HTTPAnswerJourneyDriver {
  private let clock = TestClock()
  private let framework = FakeCallingFramework()
  private let push = FakePushSource()
  private let media = FakeMedia()
  private let configuration: VoIPConfiguration
  private let events = ObservedEvents()
  private var engine: SpecEngine?
  private var installedCall: CallID?
  private var claim: Task<Void, Never>?
  private var reconciliation: Task<Void, Never>?
  private var audioActivated = false

  private final class ObservedEvents: Sendable {
    @VoIPActor var values: [CallEvent] = []
  }

  init(configuration: SpecJourney.Configuration) {
    self.configuration = configuration.sdkConfiguration
  }

  func run(_ journey: HTTPAnswerJourney) async throws {
    do {
      try await runSteps(journey)
    } catch {
      try? await finish()
      throw error
    }
    try await finish()
  }

  private func finish() async throws {
    engine?.close()
    try HTTPAnswerStub.finishIfPending(.claim)
    try HTTPAnswerStub.finishIfPending(.reconcile)
    if framework.records.contains(.fulfill(a1)) {
      try await HTTPAnswerStub.waitFor(.release)
    }
    try HTTPAnswerStub.finishIfPending(.release)
    await claim?.value
    await reconciliation?.value
  }

  private func runSteps(_ journey: HTTPAnswerJourney) async throws {
    for (index, step) in journey.steps.enumerated() {
      let message = Comment(rawValue: "\(journey.id), step \(index + 1)")
      switch step {
      case .standard(.input(let input)): try await apply(input, message: message)
      case .standard(.expect(let expectation)): try check(expectation, message: message)
      case .install(let id, let action, let credential):
        try install(id.callID, action: action.rawValue, credential: credential)
      case .reply(let response): try await reply(response)
      case .requests(let id, let expected):
        let observations = HTTPAnswerStub.observations
        #expect(observations.allSatisfy { $0.authenticated && $0.hasJSONHeaders }, message)
        let actual = observations.compactMap(\.request)
        #expect(actual.count == observations.count, message)
        #expect(actual.filter { $0.callID == id.rawValue } == expected, message)
      }
    }
  }

  private func install(_ id: CallID, action: String, credential: String) throws {
    #expect(engine == nil)
    let base = try #require(URL(string: "https://authority.example.test"))
    let keychain = [credential: HTTPAnswerStub.bearer]
    let authority = try HTTPAnswerAuthority(
      baseURL: base, readCredential: { keychain[credential] },
      actionIdentifier: { $0 == a1 ? action : $0.rawValue.uuidString },
      send: { request, _ in
        // The stub can deliver bytes after the engine has cancelled a timed-out operation, as
        // can happen when transport completion races cancellation. Only the real clock's resource
        // timer is extended for this fixture; all acceptance deadlines use virtual time.
        let transport = Task {
          try await HTTPAnswerSession.exchange(
            request, remaining: .seconds(30), protocols: [HTTPAnswerStub.self])
        }
        return try await transport.value
      })
    let wallNow = try httpTestWallClock(clock)
    engine = SpecEngine(
      framework: framework, media: media, push: push, configuration: configuration,
      clock: clock, authority: authority, wallNow: wallNow,
      observe: { [events] in events.values.append($0) })
    installedCall = id
  }

  private func apply(_ input: SpecJourney.Input, message: Comment) async throws {
    switch input {
    case .process(let running, let javascriptAttached):
      #expect(!running && !javascriptAttached && engine == nil, message)
    case .incoming(let id, let eventID, let line, let party, let deferAdmission):
      #expect(!deferAdmission && id.callID == installedCall, message)
      try #require(engine != nil)
      let incoming = IncomingCall(
        id: id.callID, parties: [try party.sdkParty()],
        answerScope: .init(accountID: line.accountID.rawValue, lineID: line.id.rawValue),
        line: line.callingLine)
      push.deliver(.incoming(incoming, eventID: eventID.eventID))
    case .provideMedia(let id):
      #expect(id.callID == installedCall, message)
    case .action(.system, .answer(let id), false):
      let engine = try #require(engine)
      framework.send(.performAnswer(a1, id.callID, remaining: .seconds(30)))
      let task = try #require(engine.answerTask(id.callID))
      claim = task
      try await HTTPAnswerStub.waitFor(.claim)
    case .advance(let milliseconds):
      try await advance(by: milliseconds.duration)
    case .connected(let id, let eventID):
      let engine = try #require(engine)
      engine.receive(.connected, for: id.callID, eventID: eventID.eventID)
    default:
      Issue.record(Comment(rawValue: "\(message): unexpected journey input"))
    }
  }

  private func advance(by duration: Duration) async throws {
    let engine = try #require(engine)
    let id = try #require(installedCall)
    var remaining = duration
    while let delay = engine.timeUntilNextDeadline, delay <= remaining {
      try Task.checkCancellation()
      clock.advance(by: delay)
      remaining -= delay
      await engine.synchronize()
      if reconciliation == nil, let task = engine.answerTask(id, reconciling: true) {
        reconciliation = task
        try await HTTPAnswerStub.waitFor(.reconcile)
      }
    }
    clock.advance(by: remaining)
    await engine.synchronize()
  }

  private func reply(_ response: HTTPResponseFixture) async throws {
    let engine = try #require(engine)
    let id = try #require(installedCall)
    let wasEnded =
      engine.calls.first { $0.id == id }.map {
        if case .ended = $0.status { true } else { false }
      } ?? false
    guard try HTTPAnswerStub.reply(response) else { return }
    switch response.operation {
    case .claim where wasEnded:
      try await HTTPAnswerStub.waitFor(.release)
    case .claim:
      await claim?.value
    case .reconcile:
      await reconciliation?.value
    case .release:
      await claim?.value
    }
    await engine.synchronize()
    if !audioActivated, framework.records.contains(.fulfill(a1)) {
      audioActivated = true
      framework.send(.audioActivated)
    }
  }

  private func check(_ expectation: SpecJourney.Expectation, message: Comment) throws {
    let engine = try #require(engine)
    switch expectation {
    case .call(let expected):
      let actual = try #require(engine.calls.first { $0.id == expected.callID.callID })
      #expect(actual.specLifecycle == expected.lifecycle, message)
      if let line = expected.lineID {
        #expect(actual.line.id == line.lineID, message)
        #expect(actual.answerScope?.lineID == line.rawValue, message)
      }
    case .count(let id, let metric, let value):
      #expect(count(metric, for: id.callID) == value, message)
    case .participating(let ids):
      #expect(engine.participating == Set(ids.map(\.callID)), message)
    case .systemEnd(let id, .remote):
      #expect(framework.records.contains(.reportEnded(id.callID, .answeredElsewhere)), message)
    case .error(let id, let kind, let reason):
      #expect(
        events.values.contains { event in
          guard case .answerFailed(let call, a1, let failure) = event, call.id == id.callID else {
            return false
          }
          switch failure {
          case .refused(let refusal): return kind == .refused && reason == SpecV0.Refusal(refusal)
          case .claimTimedOut: return kind == .claimTimedOut
          case .invalidBudget, .unavailable: return false
          }
        }, message)
    default: Issue.record(Comment(rawValue: "\(message): unexpected journey expectation"))
    }
  }

  private func count(_ metric: SpecJourney.Metric, for id: CallID) -> Int? {
    switch metric {
    case .settlements:
      framework.records.count { $0 == .fulfill(a1) || $0 == .fail(a1) }
    case .publications:
      media.records.count { $0 == .activate }
    case .claimTimeouts:
      events.values.count {
        if case .answerClaimTimedOut(let call, a1) = $0 { call.id == id } else { false }
      }
    case .permitReleases:
      HTTPAnswerStub.observations.count {
        $0.operation == .release && $0.request?.callID == id.rawValue
      }
    default: nil
    }
  }
}

func httpTestWallClock(_ clock: TestClock) throws -> @Sendable () -> Date {
  let start = clock.now
  let epoch = try Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    .parse("2026-11-18T00:00:00.000Z")
  return {
    let time = start.duration(to: clock.now).components
    return epoch.addingTimeInterval(Double(time.seconds) + Double(time.attoseconds) / 1e18)
  }
}
