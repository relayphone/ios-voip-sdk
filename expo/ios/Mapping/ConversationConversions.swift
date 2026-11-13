import Foundation

#if SWIFT_PACKAGE
  import VoIPCore
#endif

/// Why a command from JavaScript failed, in the codes that the TypeScript API decodes.
struct CommandError: Error {
  enum Code: String {
    case invalidArguments = "invalid_arguments"
    case unknownConversation = "unknown_conversation"
    case unsupported
    case conversation
    case duplicateSDKLinkage = "duplicate_sdk_linkage"
    case deadlineExceeded = "deadline_exceeded"
    case handlerFailed = "handler_failed"
  }

  let code: Code
  let message: String

  static let invalidArguments = CommandError(code: .invalidArguments, message: "Invalid arguments")
  static let unknownConversation = CommandError(
    code: .unknownConversation, message: "Unknown conversation")

  /// The SDK's refusal of an action.
  init(_ error: ActionError) {
    switch error {
    case .unknownCall:
      self = .unknownConversation
    case .notAllowed:
      self.init(
        code: .invalidArguments, message: "The conversation's status doesn't allow this action")
    case .unsupported:
      self.init(code: .unsupported, message: "This action isn't supported")
    case .refused(let systemError):
      let message =
        systemError.map { "The system refused the action: \($0)" }
        ?? "The system refused the action"
      self.init(code: .conversation, message: message)
    }
  }

  init(code: Code, message: String) {
    self.code = code
    self.message = message
  }

  /// The failure as the TypeScript API's `ConversationFailure`.
  var json: JSONValue {
    .object(["code": .string(code.rawValue), "message": .string(message)])
  }
}

extension Party {
  /// The party that a TypeScript `Participant` names, reached at its phone number, else its email
  /// address, else its ID.
  ///
  /// A phone number may contain spaces, parentheses, hyphens and periods, which are removed; it
  /// must then be in E.164 format.
  init(participant: JSONValue) throws(CommandError) {
    let handle: Handle
    do {
      if var number = participant["phoneNumber"]?.string {
        number.removeAll { " ()-.".contains($0) }
        handle = try Handle(kind: .phoneNumber, value: number)
      } else if let email = participant["email"]?.string {
        handle = try Handle(kind: .emailAddress, value: email)
      } else if let id = participant["id"]?.string {
        handle = try Handle(kind: .generic, value: id)
      } else {
        throw CommandError.invalidArguments
      }
    } catch {
      throw .invalidArguments
    }
    let name = participant["displayName"]?.string
    self.init(handle: handle, displayName: name?.isEmpty == false ? name : nil)
  }

  /// The party as a TypeScript `Participant`, identified by its presented handle.
  var participant: JSONValue {
    var fields: [String: JSONValue] = ["id": .string(presentedHandle.value)]
    if let displayName { fields["displayName"] = .string(displayName) }
    switch presentedHandle.kind {
    case .phoneNumber: fields["phoneNumber"] = .string(presentedHandle.value)
    case .emailAddress: fields["email"] = .string(presentedHandle.value)
    case .generic: break
    }
    return .object(fields)
  }
}

extension FilterCause {
  /// The TypeScript API's `IncomingFilterReason`.
  var json: JSONValue {
    switch self {
    case .doNotDisturb: .string("doNotDisturb")
    case .blockList: .string("blockList")
    case .unspecified: .string("other")
    }
  }
}

extension PreviewReason {
  /// The TypeScript API's `PreviewReason`.
  var json: JSONValue {
    switch self {
    case .filtered(let cause): .object(["type": .string("filtered"), "cause": cause.json])
    case .answeredElsewhere: .object(["type": .string("answeredElsewhere")])
    case .policy: .object(["type": .string("policy")])
    }
  }
}

extension EndReason {
  /// The TypeScript API's `EndedReason`.
  ///
  /// A call ends as filtered only when the presentation policy doesn't preview filtered calls,
  /// which this module never configures, so the TypeScript API has no reason for it.
  var json: JSONValue {
    switch self {
    case .endedHere: .string("local")
    case .endedRemotely: .string("remoteEnded")
    case .unanswered: .string("unanswered")
    case .answeredElsewhere: .string("answeredElsewhere")
    case .declinedElsewhere: .string("declinedElsewhere")
    case .filtered, .failed: .string("failed")
    }
  }

  /// The TypeScript API's `ConversationEnd` for a call that ended at the given time. A call that
  /// failed also carries the SDK's cause, as an `EndedFailure`.
  func ended(at date: Date) -> JSONValue {
    var fields: [String: JSONValue] = ["at": .date(date), "reason": json]
    switch self {
    case .failed(let failure):
      fields["failure"] = .object(["kind": .string(failure.kind)])
    case .filtered(let cause):
      fields["failure"] = .object(["kind": .string("filtered"), "cause": cause.json])
    case .endedHere, .endedRemotely, .unanswered, .answeredElsewhere, .declinedElsewhere:
      break
    }
    return .object(fields)
  }
}

extension CallFailure {
  /// The TypeScript API's `EndedFailureKind`, which names the SDK's case.
  var kind: String {
    switch self {
    case .refused: "refused"
    case .atCapacity: "atCapacity"
    case .notPlaced: "notPlaced"
    case .media: "media"
    case .audioActivationTimedOut: "audioActivationTimedOut"
    case .audioSession: "audioSession"
    case .audioRecoveryTimedOut: "audioRecoveryTimedOut"
    case .connectTimedOut: "connectTimedOut"
    case .reconnectTimedOut: "reconnectTimedOut"
    case .actionTimedOut: "actionTimedOut"
    case .frameworkReset: "frameworkReset"
    case .server: "server"
    }
  }
}

extension PresentationOutcome {
  /// The TypeScript API's `IncomingConversationOutcome` for a call with the given ID.
  func json(id: CallID) -> JSONValue {
    switch self {
    case .presented:
      .object(["status": .string("reported"), "id": .string(id.rawValue)])
    case .previewed(let reason):
      .object(["status": .string("previewed"), "id": .string(id.rawValue), "reason": reason.json])
    case .notShown:
      .object(["status": .string("notShown")])
    case .filtered(let cause):
      .object(["status": .string("filtered"), "reason": cause.json])
    case .refused(.atCapacity):
      .object(["status": .string("atCapacity")])
    case .refused:
      .object([
        "status": .string("failed"),
        "error": CommandError(code: .conversation, message: "The system refused the call").json,
      ])
    }
  }
}

extension CallStatus {
  /// The fields of a TypeScript `Conversation` that its status determines.
  ///
  /// A call on hold is `held`; termination takes precedence over hold and transport progress.
  func fields(isOnHold: Bool, endedAt: Date) -> [String: JSONValue] {
    switch self {
    case .ringing:
      ["status": .string("ringing")]
    case .previewing(let reason):
      ["status": .string("previewing"), "previewReason": reason.json]
    case .ended(let reason):
      ["status": .string("ended"), "ended": reason.ended(at: endedAt)]
    case _ where isOnHold:
      ["status": .string("held")]
    case .dialing:
      ["status": .string("dialing")]
    case .connecting:
      ["status": .string("connecting")]
    case .reconnecting:
      ["status": .string("reconnecting")]
    case .connected:
      ["status": .string("connected")]
    }
  }
}

extension Data {
  /// The bytes as lowercase hexadecimal, as servers receive APNs tokens.
  var hex: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
