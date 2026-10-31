import Dispatch
import Testing
import VoIPCore

@VoIPActor private var counter = 0

@Suite struct VoIPActorTests {
  @Test func runsACallbackOnTheQueueOnTheActor() async {
    // A system framework calls back on the queue from outside Swift concurrency.
    let result = await withCheckedContinuation { continuation in
      VoIPActor.queue.async {
        let value = VoIPActor.assumeIsolated {
          counter += 1
          return counter
        }
        continuation.resume(returning: value)
      }
    }
    #expect(result == 1)
    #expect(await counter == 1)
  }

  @Test func rethrowsTheWorksError() async {
    struct Failure: Error {}
    let rethrown = await withCheckedContinuation { continuation in
      VoIPActor.queue.async {
        do {
          try VoIPActor.assumeIsolated { () throws -> Void in throw Failure() }
          continuation.resume(returning: false)
        } catch {
          continuation.resume(returning: error is Failure)
        }
      }
    }
    #expect(rethrown)
  }
}
