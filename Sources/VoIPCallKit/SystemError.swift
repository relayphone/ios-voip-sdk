#if os(iOS)
  import CallKit
  #if SWIFT_PACKAGE
    import VoIPCore
  #endif

  /// The errors CallKit completes reports and requests with, as the SDK reads them.
  enum SystemError {
    /// What the system did with an incoming call, from the error its report completed with.
    static func presentationOutcome(for error: (any Error)?) -> PresentationOutcome {
      guard let error else { return .presented }
      return switch (error as? CXErrorCodeIncomingCallError)?.code {
      // The system already has the call, so it is presented.
      case .callUUIDAlreadyExists: .presented
      case .filteredByDoNotDisturb: .filtered(.doNotDisturb)
      case .filteredByBlockList: .filtered(.blockList)
      default: .refused(.refused)
      }
    }

    /// Why the system refused an action that the app requested.
    static func actionError(for error: any Error) -> ActionError {
      (error as? CXErrorCodeRequestTransactionError)?.code == .unknownCallUUID
        ? .unknownCall : .refused
    }
  }
#endif
