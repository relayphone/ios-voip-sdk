import Foundation

#if SWIFT_PACKAGE
  public import VoIPLiveActivity
#endif

/// A center of Live Activities that records what the SDK asks of it and answers as the test
/// scripts, so that call previews can be tested without ActivityKit.
///
/// Like the system, it starts a Live Activity only while ``isInForeground`` and
/// ``authorization`` allow it. Use ``startFromPush(_:state:)`` to act as the app's servers
/// starting a call preview with a push-to-start token, and ``send(_:)`` to act as the system.
@MainActor
public final class FakeLiveActivityCenter: LiveActivityCenter {
  /// Something the SDK asked of the center.
  public enum Record: Hashable, Sendable {
    /// The SDK started a Live Activity.
    case request(
      LiveActivityID, CallPreviewAttributes, CallPreviewAttributes.ContentState,
      staleAfter: Duration?)
    /// The SDK updated a Live Activity.
    case update(LiveActivityID, CallPreviewAttributes.ContentState, staleAfter: Duration?)
    /// The SDK ended a Live Activity.
    case end(LiveActivityID, CallPreviewAttributes.ContentState?, CallPreviewDismissal)
  }

  /// Everything the SDK asked of the center, in order.
  public private(set) var records: [Record] = []

  /// The Live Activities that run, by identifier.
  public private(set) var activities: [LiveActivityID: CallPreviewAttributes] = [:]

  /// Whether the user allows the app's Live Activities, and their frequent updates. Change it
  /// with ``send(_:)`` and `LiveActivityEvent.authorizationChanged(_:)`.
  public private(set) var authorization: LiveActivityAuthorization

  /// Whether the app is in the foreground, where the system lets it start Live Activities.
  /// Defaults to `true`.
  public var isInForeground = true

  /// An error that each request throws, as the system refuses, or `nil` to start the Live
  /// Activity. Defaults to `nil`.
  public var requestError: CallPreviewError?

  private var onEvent: (@MainActor (LiveActivityEvent) -> Void)?
  private var pushToStartToken: Data?
  private var states: [LiveActivityID: CallPreviewAttributes.ContentState] = [:]
  private var pushTokens: [LiveActivityID: Data] = [:]
  private var order: [LiveActivityID] = []
  private var count = 0

  /// Creates a fake center of Live Activities.
  ///
  /// - Parameter authorization: Whether the user allows the app's Live Activities, and their
  ///   frequent updates. Defaults to both.
  public init(
    authorization: LiveActivityAuthorization = LiveActivityAuthorization(
      areActivitiesEnabled: true, frequentPushesEnabled: true)
  ) {
    self.authorization = authorization
  }

  /// Starts a Live Activity as the system does for a push-to-start push from the app's servers,
  /// whether or not the app is in the foreground.
  ///
  /// - Parameters:
  ///   - attributes: The call that the Live Activity previews.
  ///   - state: What the Live Activity shows first.
  /// - Returns: The Live Activity's identifier.
  @discardableResult
  public func startFromPush(
    _ attributes: CallPreviewAttributes, state: CallPreviewAttributes.ContentState
  ) -> LiveActivityID {
    let id = nextID()
    send(.started(id, attributes, state))
    return id
  }

  /// Tells the SDK something as the system does, and keeps track of the Live Activities, the
  /// push-to-start token and the authorization that the event changes.
  ///
  /// Before the SDK attaches, the center keeps the Live Activities, their push tokens and the
  /// push-to-start token, and reports them when it attaches.
  ///
  /// - Parameter event: The event.
  public func send(_ event: LiveActivityEvent) {
    switch event {
    case .started(let id, let attributes, let state):
      if activities[id] == nil { order.append(id) }
      activities[id] = attributes
      states[id] = state
    case .ended(let id):
      guard activities.removeValue(forKey: id) != nil else { return }
      states[id] = nil
      pushTokens[id] = nil
      order.removeAll { $0 == id }
    case .pushToStartTokenChanged(let token):
      pushToStartToken = token
    case .authorizationChanged(let authorization):
      self.authorization = authorization
    case .pushTokenChanged(let id, let token):
      if activities[id] != nil { pushTokens[id] = token }
    }
    onEvent?(event)
  }

  // MARK: LiveActivityCenter

  /// Reports the Live Activities that run, with their push tokens, and the push-to-start token,
  /// then sends events to the SDK.
  public func attach(onEvent: @escaping @MainActor (LiveActivityEvent) -> Void) {
    self.onEvent = onEvent
    for id in order {
      guard let attributes = activities[id], let state = states[id] else { continue }
      onEvent(.started(id, attributes, state))
      if let token = pushTokens[id] { onEvent(.pushTokenChanged(id, token)) }
    }
    if let pushToStartToken { onEvent(.pushToStartTokenChanged(pushToStartToken)) }
  }

  /// Records the request and starts the Live Activity, or throws as the system would.
  public func request(
    _ attributes: CallPreviewAttributes, state: CallPreviewAttributes.ContentState,
    staleAfter: Duration?
  ) throws(CallPreviewError) -> LiveActivityID {
    guard authorization.areActivitiesEnabled else { throw .activitiesDisabled }
    guard isInForeground else { throw .notInForeground }
    if let requestError { throw requestError }
    let id = nextID()
    records.append(.request(id, attributes, state, staleAfter: staleAfter))
    send(.started(id, attributes, state))
    return id
  }

  /// Records the update.
  public func update(
    _ id: LiveActivityID, state: CallPreviewAttributes.ContentState, staleAfter: Duration?
  ) async {
    records.append(.update(id, state, staleAfter: staleAfter))
    if activities[id] != nil { states[id] = state }
  }

  /// Records the end, and ends the Live Activity.
  public func end(
    _ id: LiveActivityID, state: CallPreviewAttributes.ContentState?,
    dismissal: CallPreviewDismissal
  ) async {
    records.append(.end(id, state, dismissal))
    send(.ended(id))
  }

  private func nextID() -> LiveActivityID {
    count += 1
    return LiveActivityID(rawValue: "activity-\(count)")
  }
}
