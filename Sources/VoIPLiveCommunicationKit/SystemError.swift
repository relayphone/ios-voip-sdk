import Foundation

#if SWIFT_PACKAGE
  import VoIPCore
#endif

/// The errors LiveCommunicationKit passes on from the call service.
///
/// They keep CallKit's error domains and codes. The adapter compares them by name, so that it
/// never links CallKit, which apps distributed in China must not do.
enum SystemError {
  /// CallKit's incoming-call error domain, and the codes the SDK tells apart.
  enum IncomingCall {
    static let domain = "com.apple.CallKit.error.incomingcall"
    static let callUUIDAlreadyExists = 2
    static let filteredByDoNotDisturb = 3
    static let filteredByBlockList = 4
  }

  /// CallKit's transaction error domain, and the codes the SDK tells apart.
  enum RequestTransaction {
    static let domain = "com.apple.CallKit.error.requesttransaction"
    static let unknownCallUUID = 4
  }

  /// What the system did with an incoming call whose report failed with an error.
  static func presentationOutcome(for error: any Error) -> PresentationOutcome {
    switch code(of: error, in: IncomingCall.domain) {
    // The system already has the call, so it is presented.
    case IncomingCall.callUUIDAlreadyExists: .presented
    case IncomingCall.filteredByDoNotDisturb: .filtered(.doNotDisturb)
    case IncomingCall.filteredByBlockList: .filtered(.blockList)
    default: .refused(.refused)
    }
  }

  /// Why the system refused an action that the app requested, keeping the system's error.
  static func actionError(for error: any Error) -> ActionError {
    code(of: error, in: RequestTransaction.domain) == RequestTransaction.unknownCallUUID
      ? .unknownCall : .refused(FrameworkError(error))
  }

  /// The error's code in a domain, looking through a few levels of underlying errors, where
  /// LiveCommunicationKit keeps the call service's error.
  private static func code(of error: any Error, in domain: String) -> Int? {
    var candidate: NSError? = error as NSError
    for _ in 0..<4 {
      guard let current = candidate else { return nil }
      if current.domain == domain { return current.code }
      candidate = current.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return nil
  }
}
