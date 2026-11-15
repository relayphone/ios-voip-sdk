import CKSimProtocol
import Testing

@testable import CKSimRuntime

struct RuntimeProcessLifecycleTests {
  @Test func readinessRequiresAnObservedEntryAndNeverInventsOne() {
    var lifecycle = RuntimeProcessLifecycle()
    let premature = lifecycle.observe(.runtimeReady, at: 200)
    #expect(premature == nil)
    #expect(lifecycle.entered == nil && lifecycle.runtimeReady == nil)
    let zero = lifecycle.observe(.entered, at: 0)
    #expect(zero == nil)
    #expect(lifecycle.entered == nil)
  }

  @Test func realObservationTimesAndSourcesAreRetainedOnce() throws {
    var lifecycle = RuntimeProcessLifecycle()
    let entryObservation = lifecycle.observe(.entered, at: 100)
    let entered = try #require(entryObservation)
    #expect(entered.event == .entered && entered.source == .runtimePreparation)
    #expect(entered.uptimeNanoseconds == 100)
    let repeatedEntry = lifecycle.observe(.entered, at: 150)
    let backwards = lifecycle.observe(.runtimeReady, at: 99)
    #expect(repeatedEntry == nil && backwards == nil)
    let readyObservation = lifecycle.observe(.runtimeReady, at: 200)
    let ready = try #require(readyObservation)
    #expect(ready.event == .runtimeReady && ready.source == .hooksInstalled)
    #expect(ready.uptimeNanoseconds == 200)
    let repeatedReady = lifecycle.observe(.runtimeReady, at: 300)
    #expect(repeatedReady == nil)
    #expect(lifecycle.entered == entered && lifecycle.runtimeReady == ready)
  }

  @Test func equalUptimeStillRepresentsTwoDistinctBoundaries() {
    var lifecycle = RuntimeProcessLifecycle()
    let entered = lifecycle.observe(.entered, at: 100)
    let ready = lifecycle.observe(.runtimeReady, at: 100)
    #expect(entered != nil && ready != nil)
  }

  @Test func newInvocationHasNoPreviousBoundaries() {
    var first = RuntimeProcessLifecycle()
    _ = first.observe(.entered, at: 100)
    _ = first.observe(.runtimeReady, at: 200)
    var next = RuntimeProcessLifecycle()
    #expect(next.entered == nil && next.runtimeReady == nil)
    let premature = next.observe(.runtimeReady, at: 300)
    let entered = next.observe(.entered, at: 400)
    #expect(premature == nil && entered?.uptimeNanoseconds == 400)
    #expect(first.entered?.uptimeNanoseconds == 100)
  }
}
