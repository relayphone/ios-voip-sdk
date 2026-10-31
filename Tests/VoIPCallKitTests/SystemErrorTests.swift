#if os(iOS)
  import CallKit
  import Foundation
  import Testing
  import VoIPCore

  @testable import VoIPCallKit

  @Suite struct SystemErrorTests {
    @Test(arguments: [
      (CXErrorCodeIncomingCallError.Code.callUUIDAlreadyExists, PresentationOutcome.presented),
      (.filteredByDoNotDisturb, .filtered(.doNotDisturb)),
      (.filteredByBlockList, .filtered(.blockList)),
      (.unknown, .refused(.refused)),
      (.unentitled, .refused(.refused)),
      (.filteredDuringRestrictedSharingMode, .refused(.refused)),
      (.callIsProtected, .refused(.refused)),
      (.filteredBySensitiveParticipants, .refused(.refused)),
    ])
    func mapsIncomingReportErrors(
      _ code: CXErrorCodeIncomingCallError.Code, _ outcome: PresentationOutcome
    ) {
      let error = NSError(domain: CXErrorDomainIncomingCall, code: code.rawValue)
      #expect(SystemError.presentationOutcome(for: error) == outcome)
    }

    @Test func presentsAReportWithoutAnError() {
      #expect(SystemError.presentationOutcome(for: nil) == .presented)
    }

    @Test func refusesReportErrorsFromOtherDomains() {
      #expect(SystemError.presentationOutcome(for: CancellationError()) == .refused(.refused))
      let request = NSError(
        domain: CXErrorDomainRequestTransaction,
        code: CXErrorCodeIncomingCallError.Code.filteredByDoNotDisturb.rawValue)
      #expect(SystemError.presentationOutcome(for: request) == .refused(.refused))
    }

    @Test(arguments: [
      (CXErrorCodeRequestTransactionError.Code.unknownCallUUID, ActionError.unknownCall),
      (.maximumCallGroupsReached, .refused), (.invalidAction, .refused), (.unknown, .refused),
    ])
    func mapsActionErrors(_ code: CXErrorCodeRequestTransactionError.Code, _ error: ActionError) {
      let system = NSError(domain: CXErrorDomainRequestTransaction, code: code.rawValue)
      #expect(SystemError.actionError(for: system) == error)
    }

    @Test func refusesActionErrorsFromOtherDomains() {
      let incoming = NSError(
        domain: CXErrorDomainIncomingCall,
        code: CXErrorCodeRequestTransactionError.Code.unknownCallUUID.rawValue)
      #expect(SystemError.actionError(for: incoming) == .refused)
    }
  }
#endif
