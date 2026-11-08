import Testing
import VoIPCore
import VoIPTesting

@testable import VoIPConversationsMapping

extension MappingClientTests {
  @Suite
  @MainActor
  struct ActionWaiterTests {
    @Test
    func latePlacementAndLongPreparationWaitForThePerformedEvent() async throws {
      let h = try Harness()
      await prepare(h.media, with: .wait)
      let waiter = ActionWaiter(h.action, deadlines: h.deadlines, clock: h.clock)
      try await h.client.request(h.action)
      guard case .startRequested = try await h.next() else {
        Issue.record("The SDK asks the handler to place the outgoing call")
        return
      }
      let result = Resolution()
      let request = Task { await result.wait(for: waiter) }
      try await h.clock.waitForSleepers(count: 2)
      h.clock.advance(by: .milliseconds(8900))
      await h.client.confirmPlaced(h.id)
      try await h.clock.waitForSleepers(count: 2)
      try await waitForPreparation(h.media, of: h.id)
      h.clock.advance(by: .seconds(11))
      #expect(h.clock.pendingSleepCount == 2)
      #expect(result.value == nil)
      await h.media.finishPreparing(h.id, succeeded: true)
      let event = try await h.next()
      guard case .performed(.start, _) = event else {
        Issue.record("A prepared start produces the SDK's performed event")
        return
      }
      waiter.receive(event)
      await request.value
      guard case .success = result.value else {
        Issue.record("The command succeeds only after the SDK performs the start")
        return
      }
      try await h.clock.waitForSleepers(count: 2)
      #expect(h.clock.pendingSleepCount == 2)
    }

    @Test
    func failedMediaPreparationRejectsTheStartEvenBeforeWaitBegins() async throws {
      let h = try Harness()
      await prepare(h.media, with: .fail)
      let waiter = ActionWaiter(h.action, deadlines: h.deadlines, clock: h.clock)
      try await h.client.request(h.action)
      _ = try await h.next()
      await h.client.confirmPlaced(h.id)
      let event = try await h.next()
      guard case .ended(let call) = event else {
        Issue.record("Failed preparation ends the outgoing call")
        return
      }
      #expect(call.status == .ended(.failed(.media)))
      waiter.receive(event)
      do {
        try await waiter.wait()
        Issue.record("A failed start must reject the command")
      } catch {
        #expect(error.code == .conversation)
      }
    }

    @Test
    func aMissingOutcomeRejectsAtTheConfiguredBound() async throws {
      let clock = TestClock()
      let deadlines = Deadlines(placement: .seconds(10.5), mediaPreparation: .seconds(20.25))
      let waiter = ActionWaiter(
        .start(OutgoingCall(id: CallID(rawValue: "no-outcome"), parties: [])),
        deadlines: deadlines, clock: clock)
      let result = Resolution()
      let request = Task { await result.wait(for: waiter) }
      try await clock.waitForSleepers()
      clock.advance(by: .seconds(35.75) - .nanoseconds(1))
      #expect(clock.pendingSleepCount == 1)
      #expect(result.value == nil)
      clock.advance(by: .nanoseconds(1))
      await request.value
      guard case .failure(let error) = result.value else {
        Issue.record("A request without an outcome rejects instead of resolving successfully")
        return
      }
      #expect(error.code == .deadlineExceeded)
      #expect(error.message == "The SDK didn't carry out the request in time")
      #expect(clock.pendingSleepCount == 0)
    }
  }

}

@VoIPActor
private func prepare(_ media: FakeMedia, with preparation: FakeMedia.Preparation) {
  media.preparation = preparation
}

@VoIPActor
private func waitForPreparation(_ media: FakeMedia, of id: CallID) async throws {
  while !media.waitingCalls.contains(id) {
    try Task.checkCancellation()
    await Task.yield()
  }
}

@MainActor
private final class Resolution {
  var value: Result<Void, CommandError>?

  func wait(for waiter: ActionWaiter) async {
    do {
      try await waiter.wait()
      value = .success(())
    } catch {
      value = .failure(error)
    }
  }
}

@MainActor
private final class Harness {
  let id = CallID(rawValue: "app-call")
  let deadlines = Deadlines(mediaPreparation: .seconds(20))
  let clock = TestClock()
  let media = FakeMedia()
  let client: VoIPClient
  private var events: AsyncStream<CallEvent>.Iterator

  var action: Action { .start(OutgoingCall(id: id, parties: [])) }

  init() throws {
    client = try VoIPClient.start(
      framework: FakeCallingFramework(), media: media,
      configuration: VoIPConfiguration(deadlines: deadlines), clock: clock)
    events = client.events().makeAsyncIterator()
  }

  func next() async throws -> CallEvent {
    var events = events
    let event = await events.next(isolation: #isolation)
    self.events = events
    return try #require(event)
  }
}
