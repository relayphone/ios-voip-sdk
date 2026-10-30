import Foundation
public import VoIPCore

/// A calling framework that records what the SDK asks of it and answers as the test scripts, so
/// that the SDK can be tested without CallKit or LiveCommunicationKit.
///
/// Like the system, it asks the SDK to perform each action that the app requests. Use
/// ``perform(_:)`` and ``send(_:)`` to act as the user on the system's calling surfaces, or as the
/// system itself.
@VoIPActor
public final class FakeCallingFramework: CallingFramework {
  /// Something the SDK asked of the calling framework.
  public enum Record: Hashable, Sendable {
    /// The SDK reported an incoming call.
    case reportIncoming(Call)
    /// The SDK requested an action that the app asked for, with the call's details.
    case request(Action, Call)
    /// The SDK completed an action.
    case fulfill(ActionID)
    /// The SDK completed an action as failed.
    case fail(ActionID)
    /// The SDK updated a call's details.
    case update(Call)
    /// The SDK reported that a call started here began connecting, or connected.
    case reportOutgoing(CallID, connected: Bool)
    /// The SDK reported that a call ended.
    case reportEnded(CallID, EndReason)
  }

  /// How the fake answers a request.
  public enum RequestResult: Hashable, Sendable {
    /// Accept the request, then ask the SDK to perform it, as the system does.
    case perform
    /// Accept the request without asking the SDK to perform it.
    case accept
    /// Refuse the request with an error.
    case refuse(ActionError)
  }

  /// Everything the SDK asked of the fake, in order.
  public private(set) var records: [Record] = []

  /// Every event the fake sent to the SDK, in order.
  public private(set) var sentEvents: [FrameworkEvent] = []

  /// The configuration the SDK attached with, or `nil` before it attached.
  public private(set) var configuration: VoIPConfiguration?

  /// What the system does with each incoming call that the SDK reports, at once. When it is
  /// `nil`, reports wait for ``completeReports(of:with:)``. Defaults to `presented`.
  public var presentationOutcome: PresentationOutcome? = .presented

  /// How the fake answers each request. Defaults to ``RequestResult/perform``.
  public var requestResult = RequestResult.perform

  private var onEvent: (@VoIPActor (FrameworkEvent) -> Void)?
  private var waitingReports: [(call: Call, completion: @VoIPActor (PresentationOutcome) -> Void)] =
    []
  private var actionCount: UInt64 = 0

  /// Creates a fake calling framework that presents every call.
  public nonisolated init() {}

  /// The incoming calls whose reports wait for an outcome, in the order they were reported.
  public var waitingCalls: [Call] { waitingReports.map(\.call) }

  /// Completes every waiting report of a call.
  ///
  /// - Parameters:
  ///   - id: The call whose reports to complete.
  ///   - outcome: What the system did with the call.
  public func completeReports(of id: CallID, with outcome: PresentationOutcome) {
    let completing = waitingReports.filter { $0.call.id == id }
    waitingReports.removeAll { $0.call.id == id }
    for report in completing { report.completion(outcome) }
  }

  /// Asks the SDK to perform an action, as the system does when the user acts on its calling
  /// surfaces.
  ///
  /// - Parameter action: The action to perform.
  /// - Returns: The action's identifier, with which the SDK fulfils or fails it.
  @discardableResult
  public func perform(_ action: Action) -> ActionID {
    actionCount += 1
    let id = ActionID(rawValue: UUID(uuid: Self.uuid(actionCount)))
    send(.perform(id, action))
    return id
  }

  /// Sends the SDK an event, as the system does.
  ///
  /// - Parameter event: The event to send.
  public func send(_ event: FrameworkEvent) {
    guard let onEvent else { preconditionFailure("The SDK hasn't attached the calling framework") }
    sentEvents.append(event)
    onEvent(event)
  }

  // MARK: CallingFramework

  /// Records the configuration and starts sending events to the SDK.
  public func attach(
    configuration: VoIPConfiguration, onEvent: @escaping @VoIPActor (FrameworkEvent) -> Void
  ) {
    self.configuration = configuration
    self.onEvent = onEvent
  }

  /// Records the report, then completes it with ``presentationOutcome``, or keeps it waiting.
  public func reportIncoming(
    _ call: Call, completion: @escaping @VoIPActor (PresentationOutcome) -> Void
  ) {
    records.append(.reportIncoming(call))
    if let presentationOutcome {
      completion(presentationOutcome)
    } else {
      waitingReports.append((call, completion))
    }
  }

  /// Records the request and answers it as ``requestResult`` says.
  public func request(_ action: Action, for call: Call) async throws(ActionError) {
    records.append(.request(action, call))
    switch requestResult {
    case .perform: perform(action)
    case .accept: break
    case .refuse(let error): throw error
    }
  }

  /// Records that the SDK completed an action.
  public func fulfill(_ id: ActionID) {
    records.append(.fulfill(id))
  }

  /// Records that the SDK completed an action as failed.
  public func fail(_ id: ActionID) {
    records.append(.fail(id))
  }

  /// Records a call's new details.
  public func update(_ call: Call) {
    records.append(.update(call))
  }

  /// Records that a call started here began connecting, or connected.
  public func reportOutgoing(_ id: CallID, connected: Bool) {
    records.append(.reportOutgoing(id, connected: connected))
  }

  /// Records that a call ended.
  public func reportEnded(_ id: CallID, reason: EndReason) {
    records.append(.reportEnded(id, reason))
  }

  private static func uuid(_ number: UInt64) -> uuid_t {
    let bytes = withUnsafeBytes(of: number.bigEndian) { Array($0) }
    return (
      0xFA, 0xCE, 0, 0, 0, 0, 0, 0, bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
      bytes[6], bytes[7]
    )
  }
}
