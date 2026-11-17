#if DEBUG && (os(macOS) || (os(iOS) && targetEnvironment(simulator)))
  import Foundation
  import Testing
  @_spi(Simulator) import VoIPCore

  @testable import CKSimRuntime

  struct RuntimeBackgroundObservationTests {
    @Test(arguments: [SimulatorBackgroundExecution.Source.applicationAssertion, .sdkPushAssertion])
    func preservesEveryBoundaryAndItsActualCallbackTime(source: SimulatorBackgroundExecution.Source)
      throws
    {
      let id = UUID()
      for kind in [
        SimulatorBackgroundExecution.Event.Kind.requested, .began, .denied, .expired, .ended,
      ] {
        let event = SimulatorBackgroundExecution.Event(
          id: id, source: source, kind: kind, uptimeNanoseconds: 1500)
        let row = try #require(RuntimeBackgroundObservation(event, epoch: 1000, now: 2000))
        #expect(row.id == id && row.source == source)
        #expect(row.name == "backgroundAssertion.\(kind.rawValue)")
        #expect(row.uptimeNanoseconds == 1500)
      }
    }

    @Test func rejectsAnotherRuntimeEpochAndFutureEvents() {
      for time in [UInt64(999), 2001] {
        let event = SimulatorBackgroundExecution.Event(
          id: UUID(), source: .applicationAssertion, kind: .began, uptimeNanoseconds: time)
        #expect(RuntimeBackgroundObservation(event, epoch: 1000, now: 2000) == nil)
      }
    }
  }
#endif
