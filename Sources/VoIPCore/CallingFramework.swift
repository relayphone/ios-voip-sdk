/// The Apple system framework that presents calls to the user on this device: LiveCommunicationKit
/// or CallKit.
///
/// An app links exactly one adapter that conforms to this protocol. The SDK keeps every call's
/// state itself and uses the calling framework only to present calls and to learn what the user
/// does on the system's calling surfaces. Adapters name each call to the system by
/// ``deviceUUID(for:)``.
@VoIPActor
public protocol CallingFramework: Sendable {
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
  /// call before the push callback returns, as Apple requires. Reporting a call whose UUID the
  /// system already has doesn't present it again, which the SDK relies on to satisfy a repeated
  /// VoIP push.
  ///
  /// - Parameters:
  ///   - call: The call to report.
  ///   - completion: Called once with what the system did with the call.
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
  /// - Throws: ``ActionError/refused`` when the system refuses the action, or
  ///   ``ActionError/unknownCall`` when the system doesn't know the call.
  func request(_ action: Action, for call: Call) async throws(ActionError)

  /// Completes an action the system asked the SDK to perform.
  ///
  /// - Parameter id: The action's identifier.
  func fulfill(_ id: ActionID)

  /// Completes an action the system asked the SDK to perform as failed.
  ///
  /// - Parameter id: The action's identifier.
  func fail(_ id: ActionID)

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

  /// Tells the system that a call ended without the user ending it on this device.
  ///
  /// - Parameters:
  ///   - id: The call.
  ///   - reason: Why the call ended.
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
