#if DEBUG && (os(macOS) || (os(iOS) && targetEnvironment(simulator)))
  import Foundation
  import Testing
  import VoIPCore

  @testable import CKSimRuntime

  struct RuntimePacketObservationTests {
    @Test(arguments: [MediaTransportEvent.Kind.firstPacketReceived, .firstPacketSent])
    func observationUsesRuntimeEpochAndPreservesIdentity(kind: MediaTransportEvent.Kind) throws {
      let now = SuspendingClock.now
      let id = CallID(rawValue: "packet-call")
      let event = MediaTransportEvent(
        callID: id, kind: kind, observedAt: now.advanced(by: .milliseconds(-1250)))
      let row = try #require(RuntimePacketObservation(event, receivedAt: now, elapsed: .seconds(5)))
      #expect(row.callID == id.rawValue)
      #expect(row.callUUID == deviceUUID(for: id))
      #expect(row.observedAtMS == 3750)
      #expect(
        row.name
          == (kind == .firstPacketReceived ? "sdk.firstPacketReceived" : "sdk.firstPacketSent"))
    }

    @Test func observationsBeforeRuntimeOrFromFutureAreDiscarded() {
      let now = SuspendingClock.now
      let id = CallID(rawValue: "other-packet-call")
      for offset in [Duration.seconds(-6), .seconds(1)] {
        let event = MediaTransportEvent(
          callID: id, kind: .firstPacketSent, observedAt: now.advanced(by: offset))
        #expect(RuntimePacketObservation(event, receivedAt: now, elapsed: .seconds(5)) == nil)
      }
    }
  }
#endif
