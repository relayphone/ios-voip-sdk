import Testing
import VoIPCore
import VoIPTesting

@testable import VoIPNotifications

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct NotifierBackgroundExecutionTests {
  @Test func postAndWithdrawEachHoldOneTaskUntilTheCenterReturns() async throws {
    let execution = FakeNotifierBackgroundExecution()
    let center = HoldingNotificationCenter()
    let notifier = CallNotifier(
      center: center, activity: nil, clock: TestClock(), backgroundExecution: execution)
    let (events, input) = AsyncStream.makeStream(of: CallEvent.self)
    defer { input.finish() }
    var results = notifier.events().makeAsyncIterator()
    var operations = center.operations.makeAsyncIterator()
    notifier.follow(events)

    input.yield(.previewStarted(call(.previewing(dnd))))
    #expect(await operations.next() == .post)
    #expect(execution.begun == 1)
    #expect(execution.active == [1])
    center.resume()
    #expect(await results.next() == .posted(notification(.incoming)))
    #expect(execution.active.isEmpty)
    #expect(execution.ended == [1])

    input.yield(.performed(.join(callID), call(.connecting)))
    #expect(await operations.next() == .withdraw)
    #expect(execution.begun == 2)
    #expect(execution.active == [2])
    center.resume()
    #expect(await results.next() == .withdrawn(callID))
    #expect(execution.active.isEmpty)
    #expect(execution.ended == [1, 2])
    #expect(center.fake.records == [.post(notification(.incoming)), .withdraw(callID)])
  }

  @Test func aRefusedPostAlsoEndsItsBackgroundTask() async {
    let execution = FakeNotifierBackgroundExecution()
    let center = HoldingNotificationCenter()
    center.fake.postError = .notAuthorized
    let notifier = CallNotifier(
      center: center, activity: nil, clock: TestClock(), backgroundExecution: execution)
    let (events, input) = AsyncStream.makeStream(of: CallEvent.self)
    defer { input.finish() }
    var results = notifier.events().makeAsyncIterator()
    var operations = center.operations.makeAsyncIterator()
    notifier.follow(events)
    input.yield(.previewStarted(call(.previewing(dnd))))
    #expect(await operations.next() == .post)
    #expect(execution.active == [1])
    center.resume()
    #expect(await results.next() == .failed(notification(.incoming), .notAuthorized))
    #expect(execution.active.isEmpty)
    #expect(execution.ended == [1])
  }
}

@MainActor
private final class FakeNotifierBackgroundExecution: NotifierBackgroundExecution {
  private(set) var begun = 0
  private(set) var active: Set<Int> = []
  private(set) var ended: [Int] = []

  func begin() -> @MainActor () -> Void {
    begun += 1
    let id = begun
    active.insert(id)
    return {
      self.active.remove(id)
      self.ended.append(id)
    }
  }
}

@MainActor
private final class HoldingNotificationCenter: CallNotificationCenter {
  enum Operation { case post, withdraw }
  let fake = FakeCallNotificationCenter()
  let operations: AsyncStream<Operation>
  private let output: AsyncStream<Operation>.Continuation
  private var pending: CheckedContinuation<Void, Never>?

  init() {
    (operations, output) = AsyncStream.makeStream(of: Operation.self)
  }

  func post(_ notification: CallNotification) async throws(CallNotificationError) {
    await hold(.post)
    try await fake.post(notification)
  }

  func withdraw(_ id: CallID) async {
    await hold(.withdraw)
    await fake.withdraw(id)
  }

  func resume() {
    let pending = self.pending
    self.pending = nil
    pending?.resume()
  }

  private func hold(_ operation: Operation) async {
    await withCheckedContinuation {
      pending = $0
      output.yield(operation)
    }
  }
}
