import Testing
import VoIPCore
import VoIPExactBridge
import VoIPTesting

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct CallListBridgeTests {
  @Test
  func anOutgoingCallReportedConnectedIsPlacedThenConnected() async throws {
    let h = try Harness()
    h.bridge.follow([h.outgoing(.dialing)])
    #expect(try await h.nextOutput() == .claimAudio(hasVideo: false))
    h.bridge.follow([h.outgoing(.connected)])
    try await h.waitForStatus(.connected)
  }

  @Test
  func aListChangeBecomesAnActionAndReportsNothingBack() async throws {
    let h = try Harness()
    h.bridge.follow([h.incoming(.ringing)])
    try await h.waitForStatus(.ringing)
    h.bridge.follow([h.incoming(.connected)])
    #expect(try await h.nextOutput() == .claimAudio(hasVideo: false))
    try await h.waitForStatus(.connected)
    h.bridge.follow([h.incoming(.held)])
    try await h.waitUntil { h.client.calls.first?.isOnHold == true }
    h.bridge.follow([h.incoming(.connected)])
    try await h.waitUntil { h.client.calls.first?.isOnHold == false }
    h.bridge.follow([h.incoming(.connected, muted: true)])
    try await h.waitUntil { h.client.calls.first?.isMuted == true }
    h.bridge.follow([h.incoming(.ended, reason: .local)])
    #expect(try await h.nextOutput() == .releaseAudio)
    try await h.waitUntil { h.client.calls.isEmpty }
  }

  @Test
  func thePersonsActsBecomeChoicesAndTheirEchoAsksNothing() async throws {
    let h = try Harness()
    h.bridge.follow([h.incoming(.ringing)])
    try await h.waitForStatus(.ringing)
    _ = await h.framework.perform(.answer(h.id))
    #expect(try await h.nextOutput() == .claimAudio(hasVideo: false))
    #expect(try await h.nextOutput() == .choice(h.id, .answer))
    try await h.waitForStatus(.connected)
    h.bridge.follow([h.incoming(.connected)])
    _ = await h.framework.perform(.hold(h.id, onHold: true))
    #expect(try await h.nextOutput() == .choice(h.id, .hold))
    h.bridge.follow([h.incoming(.held)])
    _ = await h.framework.perform(.end(h.id))
    #expect(try await h.nextOutput() == .choice(h.id, .hangup))
    h.bridge.follow([h.incoming(.ended, reason: .local)])
    #expect(try await h.nextOutput() == .releaseAudio)
    #expect(await h.requestCount() == 0)
  }

  @Test
  func aCallThePlatformStartedIsReportedOnceAndItsListingAsksNothing() async throws {
    let h = try Harness()
    _ = await h.client.report(IncomingCall(id: h.id, parties: [h.party]))
    #expect(try await h.nextOutput() == .report(h.incoming(.ringing)))
    h.bridge.follow([h.incoming(.ringing)])
    #expect(await h.reportCount() == 1)
    _ = await h.framework.perform(.answer(h.id))
    #expect(try await h.nextOutput() == .claimAudio(hasVideo: false))
    #expect(try await h.nextOutput() == .choice(h.id, .answer))
  }

  @Test
  func theRemoteEndingACallEndsItWithoutARequest() async throws {
    let h = try Harness()
    h.bridge.follow([h.incoming(.ringing)])
    try await h.waitForStatus(.ringing)
    h.bridge.follow([h.incoming(.ended, reason: .answeredElsewhere)])
    try await h.waitForFrameworkEnd(.answeredElsewhere)
    #expect(await h.requestCount() == 0)
  }
}

@MainActor
private final class Harness {
  let id = CallID(rawValue: "call")
  let party: Party
  let framework = FakeCallingFramework()
  let clock = TestClock()
  let bridge = CallListBridge()
  let client: VoIPClient
  private var outputs: AsyncStream<CallListBridge.Output>.Iterator

  init() throws {
    party = Party(
      handle: try Handle(kind: .phoneNumber, value: "+15555550100"), displayName: "Caller")
    client = try VoIPClient.start(
      framework: framework, media: FakeMedia(), observers: [bridge], clock: clock)
    outputs = bridge.outputs.makeAsyncIterator()
  }

  func incoming(
    _ state: CallListState, muted: Bool = false, reason: CallListEndReason? = nil
  ) -> CallListEntry {
    CallListEntry(
      id: id, party: party, isIncoming: true, state: state, isMuted: muted, endedReason: reason)
  }

  func outgoing(_ state: CallListState) -> CallListEntry {
    CallListEntry(id: id, party: party, isIncoming: false, state: state)
  }

  func requestCount() async -> Int {
    await framework.records.count {
      if case .request = $0 { true } else { false }
    }
  }

  func reportCount() async -> Int {
    await framework.records.count {
      if case .reportIncoming = $0 { true } else { false }
    }
  }

  func nextOutput() async throws -> CallListBridge.Output {
    var outputs = outputs
    let output = await outputs.next(isolation: #isolation)
    self.outputs = outputs
    return try #require(output)
  }

  func waitForStatus(_ status: CallStatus) async throws {
    try await waitUntil { self.client.calls.first?.status == status }
  }

  func waitForFrameworkEnd(_ reason: EndReason) async throws {
    for _ in 0..<2000 {
      if await framework.records.contains(.reportEnded(id, reason)) { return }
      await Task.yield()
    }
    Issue.record("The framework was never told the call ended")
  }

  func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<2000 {
      if condition() { return }
      await Task.yield()
    }
    Issue.record("The condition never held")
  }
}
