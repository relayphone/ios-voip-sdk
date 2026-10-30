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

  @Test(arguments: [(4, ActionError.unknownCall), (7, .refused), (0, .refused)])
  func mapsActionErrors(_ code: Int, _ error: ActionError) {
    #expect(SystemError.actionError(for: wrapped(Self.requestTransaction, code)) == error)
  }

  @Test func refusesActionErrorsFromOtherDomains() {
    #expect(SystemError.actionError(for: wrapped(Self.incomingCall, 4)) == .refused)
  }
}
