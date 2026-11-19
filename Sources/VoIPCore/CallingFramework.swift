/// The Apple system framework that presents calls to the user on this device: LiveCommunicationKit.
///
/// `LiveCommunicationKitAdapter` conforms to this protocol in apps, and `FakeCallingFramework` in
/// tests. The SDK keeps every call's state itself and uses the calling framework only to present
/// calls and to learn what the user does on the system's calling surfaces. Adapters name each call
/// to the system by ``deviceUUID(for:)``.
@VoIPActor
public protocol CallingFramework: Sendable {
  /// The platform this adapter represents when reporting system failures.
  var platform: SystemFailure.Platform { get }

  /// Starts the calling framework with the app's configuration.
  ///
  /// The SDK calls this once, before any other method. The adapter calls `onEvent` for everything
  /// the system tells it, synchronously from the system's callback, so that the SDK can start audio
  /// while the system waits.
  ///
  /// - Parameters:
  ///   - configuration: How the app presents and controls calls.
  ///   - onEvent: Receives the system's actions and changes.
  func attach(
    configuration: VoIPConfiguration, onEvent: @escaping @VoIPActor (FrameworkEvent) -> Void)

  /// Reports an incoming call to the system, so that it can be presented.
  ///
  /// The adapter hands the report to the system before it returns: the SDK reports a VoIP push's
  /// call before the push callback returns, as Apple requires. A push that brings no new call to
  /// present, such as a server event, and must be reported is satisfied with a throwaway call
  /// under a UUID of its own, which the SDK reports and ends at once, rather than with the push's
  /// call reported again.
  ///
  /// - Parameters:
  ///   - call: The call to report.
  ///   - completion: Called once with what the system did with the call:
  ///     ``PresentationOutcome/presented``, ``PresentationOutcome/filtered(_:)`` or
  ///     ``PresentationOutcome/refused(_:)``. Use ``CallFailure/systemFailed(_:)`` with an
  ///     admission diagnostic when the system refuses to admit the call.
  func reportIncoming(
    _ call: Call, completion: @escaping @VoIPActor (PresentationOutcome) -> Void)

  /// Asks the system to perform an action that the app requested.
  ///
  /// When the system accepts, it asks the SDK to perform the action with
  /// ``FrameworkEvent/perform(_:_:)``.
  ///
  /// - Parameters:
  ///   - action: The action the app requested.
  ///   - call: The call as the SDK knows it, with the details that starting it needs, such as its
  ///     parties and whether it has video. A join names only the call in its action.
  /// - Throws: ``ActionError/refused(_:)`` with the system's error when the system refuses the
  ///   action, or ``ActionError/unknownCall`` when the system doesn't know the call.
  func request(_ action: Action, for call: Call) async throws(ActionError)

  /// Completes an action the system asked the SDK to perform.
  ///
  /// - Parameter id: The action's identifier.
  func fulfill(_ id: ActionID)

  /// Completes an action the system asked the SDK to perform as failed.
  ///
  /// - Parameter id: The action's identifier.
  func fail(_ id: ActionID)

  /// Whether this adapter can report mid-call video changes.
  var supportsVideoChanges: Bool { get }

  /// Reports video to the system and returns the value actually reported after delivery.
  /// Throws when unsupported, unknown, ended or refused; never completes optimistically.
  func setVideo(_ enabled: Bool, for call: Call) async throws(ActionError) -> Bool

  /// Updates a call's details, such as its parties, in the system.
  ///
  /// - Parameter call: The call with its new details.
  func update(_ call: Call)

  /// Tells the system that a call started on this device began connecting, or connected.
  ///
  /// - Parameters:
  ///   - id: The call.
  ///   - connected: Whether the call connected, rather than began connecting.
  func reportOutgoing(_ id: CallID, connected: Bool)

  /// Removes a call whose end the SDK has already recorded.
  ///
  /// - Parameters:
  ///   - id: The call.
  ///   - reason: The reason to present to the system. Outgoing no-answer uses
  ///     ``EndReason/endedRemotely`` and incoming no-answer uses ``EndReason/unanswered``.
  ///     For local ends, perform system removal without asking the SDK to end the call again.
  func reportEnded(_ id: CallID, reason: EndReason)
}

/// Something the calling framework tells the SDK: an action the user took on the system's calling
/// surfaces, or a change in the system's state.
public enum FrameworkEvent: Hashable, Sendable {
  /// The system asks the SDK to perform an action, such as answering when the user taps Answer.
  /// The SDK fulfils or fails it with ``CallingFramework/fulfill(_:)`` or
  /// ``CallingFramework/fail(_:)``.
  case perform(ActionID, Action)
  /// The system stopped waiting for an action to complete.
  case actionTimedOut(ActionID)
  /// The system activated the audio session for calls.
  case audioActivated
  /// The system deactivated the audio session.
  case audioDeactivated
  /// The calling framework reset, which ends every call it presents.
  case reset
}

extension CallingFramework {
  /// Swift calling frameworks represent iOS by default.
  public var platform: SystemFailure.Platform { .ios }

  /// Custom adapters opt into mid-call video explicitly.
  public var supportsVideoChanges: Bool { false }
  /// Custom adapters reject mid-call video until they implement its reporting boundary.
  public func setVideo(_ enabled: Bool, for call: Call) async throws(ActionError) -> Bool {
    throw .unsupported
  }
}
