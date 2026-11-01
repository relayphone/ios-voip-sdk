import Foundation
import Testing
import VoIPCore

@testable import VoIPLiveCommunicationKit

@Suite struct SystemErrorTests {
  private static let incomingCall = "com.apple.CallKit.error.incomingcall"
  private static let requestTransaction = "com.apple.CallKit.error.requesttransaction"

  /// An error as LiveCommunicationKit passes it on: the call service's error, wrapped `depth`
  /// times.
  private func wrapped(_ domain: String, _ code: Int, depth: Int = 1) -> NSError {
    var error = NSError(domain: domain, code: code)
    for level in 0..<depth {
      error = NSError(
        domain: "LiveCommunicationKit.wrapper\(level)", code: 1,
        userInfo: [NSUnderlyingErrorKey: error])
    }
    return error
  }

  @Test(arguments: [
    (2, PresentationOutcome.presented), (3, .filtered(.doNotDisturb)), (4, .filtered(.blockList)),
    (0, .refused(.refused)), (1, .refused(.refused)),
  ])
  func mapsIncomingReportErrors(_ code: Int, _ outcome: PresentationOutcome) {
    #expect(
      SystemError.presentationOutcome(for: NSError(domain: Self.incomingCall, code: code))
        == outcome)
    #expect(
      SystemError.presentationOutcome(for: wrapped(Self.incomingCall, code, depth: 3)) == outcome)
  }

  @Test func refusesReportErrorsFromOtherDomainsOrTooDeep() {
    #expect(SystemError.presentationOutcome(for: CancellationError()) == .refused(.refused))
    #expect(
      SystemError.presentationOutcome(for: wrapped(Self.requestTransaction, 3))
        == .refused(.refused))
    #expect(
      SystemError.presentationOutcome(for: wrapped(Self.incomingCall, 3, depth: 4))
        == .refused(.refused))
  }

  /// The error that ``wrapped(_:_:depth:)`` makes, as the SDK keeps it.
  private func kept(_ domain: String, _ code: Int) -> FrameworkError {
    FrameworkError(
      domain: "LiveCommunicationKit.wrapper0", code: 1,
      underlyingErrors: [FrameworkError(domain: domain, code: code)])
  }

  @Test func mapsAnUnknownCall() {
    #expect(SystemError.actionError(for: wrapped(Self.requestTransaction, 4)) == .unknownCall)
  }

  @Test(arguments: [7, 1, 0])
  func keepsTheSystemsErrorInARefusal(_ code: Int) {
    #expect(
      SystemError.actionError(for: wrapped(Self.requestTransaction, code))
        == .refused(kept(Self.requestTransaction, code)))
  }

  @Test func refusesActionErrorsFromOtherDomains() {
    #expect(
      SystemError.actionError(for: wrapped(Self.incomingCall, 4))
        == .refused(kept(Self.incomingCall, 4)))
  }
}
