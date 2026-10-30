import Foundation
import Synchronization
import Testing
import VoIPPushDelivery

@testable import VoIPPushKit

/// Counts the calls of a completion handler.
private final class Calls: Sendable {
  private let count = Atomic(0)
  var value: Int { count.load(ordering: .relaxed) }
  func record() { count.add(1, ordering: .relaxed) }
}

@Suite(.timeLimit(.minutes(1))) struct PushCompletionTests {
  @Test func finishCallsTheHandlerOnce() {
    let calls = Calls()
    let completion = VSPushCompletion(completion: { calls.record() }, watchdog: 3600)
    completion.finish()
    completion.finish()
    #expect(calls.value == 1)
  }

  @Test func theWatchdogCallsTheHandlerWhenThePushIsNotFinished() async {
    let calls = Calls()
    await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
      _ = VSPushCompletion(
        completion: {
          calls.record()
          finished.resume()
        }, watchdog: 0.01)
    }
    #expect(calls.value == 1)
  }
}

@Suite struct TokenUpdatesTests {
  private let first = Data([0x01, 0x02])
  private let second = Data([0x03])

  @Test func aStreamStartsWithTheCurrentTokenThenFollowsChanges() async {
    let updates = TokenUpdates()
    updates.send(first)
    var tokens = updates.stream().makeAsyncIterator()
    #expect(await tokens.next() == first)
    updates.send(first)
    updates.send(nil)
    updates.send(second)
    #expect(await tokens.next() == .some(nil))
    #expect(await tokens.next() == second)
  }

  @Test func aStreamBeforeTheFirstTokenWaitsForIt() async {
    let updates = TokenUpdates()
    let stream = updates.stream()
    updates.send(nil)
    updates.send(first)
    var tokens = stream.makeAsyncIterator()
    #expect(await tokens.next() == first)
  }

  @Test func everyStreamReceivesEachChange() async {
    let updates = TokenUpdates()
    var a = updates.stream().makeAsyncIterator()
    var b = updates.stream().makeAsyncIterator()
    updates.send(second)
    #expect(await a.next() == second)
    #expect(await b.next() == second)
  }
}
