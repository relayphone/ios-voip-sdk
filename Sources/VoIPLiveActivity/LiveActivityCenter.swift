public import Foundation

/// The system's Live Activities, as ``CallPreviewActivities`` uses them for call previews.
///
/// ``ActivityKitAdapter`` conforms to this protocol in apps, and `FakeLiveActivityCenter` in
/// tests. A center handles only Live Activities whose attributes are ``CallPreviewAttributes``,
/// whether the app started them or its servers did, with a push-to-start token.
@MainActor
public protocol LiveActivityCenter: AnyObject {
  /// Whether the user allows the app's Live Activities, and their frequent updates.
  var authorization: LiveActivityAuthorization { get }

  /// Starts telling the observer about call previews' Live Activities.
  ///
  /// The observer calls this once, before any other method. The center then calls `onEvent`
  /// with ``LiveActivityEvent/started(_:_:_:)`` for each Live Activity that already runs, and
  /// with each change from then on: Live Activities that start, end or receive a push token, a
  /// new push-to-start token, and changes to ``authorization``.
  ///
  /// - Parameter onEvent: Receives everything the system tells the center.
  func attach(onEvent: @escaping @MainActor (LiveActivityEvent) -> Void)

  /// Starts a Live Activity, with a push token for its updates.
  ///
  /// The system starts a Live Activity only while the app is in the foreground. The center sends
  /// ``LiveActivityEvent/started(_:_:_:)`` for it before it returns.
  ///
  /// - Parameters:
  ///   - attributes: The call that the Live Activity previews.
  ///   - state: What the Live Activity shows first.
  ///   - staleAfter: How long the state stays current, after which the Live Activity shows that
  ///     it is out of date, or `nil` if it never goes out of date.
  /// - Returns: The Live Activity's identifier.
  /// - Throws: ``CallPreviewError/activitiesDisabled`` when the user turned Live Activities
  ///   off, ``CallPreviewError/notInForeground`` when the app isn't in the foreground,
  ///   ``CallPreviewError/tooLarge`` when the attributes and state exceed the system's limit,
  ///   or ``CallPreviewError/refused`` when the system refuses for another reason.
  func request(
    _ attributes: CallPreviewAttributes, state: CallPreviewAttributes.ContentState,
    staleAfter: Duration?
  ) throws(CallPreviewError) -> LiveActivityID

  /// Changes what a Live Activity shows.
  ///
  /// - Parameters:
  ///   - id: The Live Activity.
  ///   - state: What it shows now.
  ///   - staleAfter: How long the state stays current, or `nil` if it never goes out of date.
  func update(
    _ id: LiveActivityID, state: CallPreviewAttributes.ContentState, staleAfter: Duration?
  ) async

  /// Ends a Live Activity.
  ///
  /// The center sends ``LiveActivityEvent/ended(_:)`` once the system ended it.
  ///
  /// - Parameters:
  ///   - id: The Live Activity.
  ///   - state: What it shows until the system removes it, or `nil` to keep what it shows.
  ///   - dismissal: When the system removes it from the Lock Screen.
  func end(
    _ id: LiveActivityID, state: CallPreviewAttributes.ContentState?,
    dismissal: CallPreviewDismissal) async
}

/// The system's identifier for one Live Activity, such as ActivityKit's activity ID.
public struct LiveActivityID: RawRepresentable, Hashable, Sendable {
  /// The system's identifier.
  public let rawValue: String

  /// Creates a Live Activity's identifier from the system's identifier.
  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Something that a ``LiveActivityCenter`` tells its observer.
public enum LiveActivityEvent: Hashable, Sendable {
  /// A call preview's Live Activity runs, with the state it shows: one the app started, or one
  /// the app's servers started with a push-to-start token.
  case started(LiveActivityID, CallPreviewAttributes, CallPreviewAttributes.ContentState)
  /// The system issued a new push token for a Live Activity, with which the app's servers update
  /// and end it.
  case pushTokenChanged(LiveActivityID, Data)
  /// A Live Activity ended, or the user or the system removed it.
  case ended(LiveActivityID)
  /// The system issued a new push-to-start token, with which the app's servers start call
  /// previews on this device.
  case pushToStartTokenChanged(Data)
  /// The user changed whether the app's Live Activities, or their frequent updates, are allowed.
  case authorizationChanged(LiveActivityAuthorization)
}

/// Whether the user allows the app's Live Activities, and their frequent updates.
///
/// The system asks the user the first time a Live Activity appears, and the user can change
/// both settings in the Settings app. Send them to the app's servers with the push tokens, so that
/// they don't start call previews that the user turned off.
public struct LiveActivityAuthorization: Hashable, Sendable {
  /// Whether the app's Live Activities can appear. ActivityKit calls this
  /// `areActivitiesEnabled`.
  public var areActivitiesEnabled: Bool

  /// Whether the app's servers may update its Live Activities often, beyond the system's usual
  /// budget for high-priority pushes. ActivityKit calls this `frequentPushesEnabled`.
  public var frequentPushesEnabled: Bool

  /// Creates the user's Live Activity settings.
  ///
  /// - Parameters:
  ///   - areActivitiesEnabled: Whether the app's Live Activities can appear.
  ///   - frequentPushesEnabled: Whether the app's servers may update them often.
  public init(areActivitiesEnabled: Bool, frequentPushesEnabled: Bool) {
    self.areActivitiesEnabled = areActivitiesEnabled
    self.frequentPushesEnabled = frequentPushesEnabled
  }
}

/// When the system removes a call preview's Live Activity from the Lock Screen once it ended.
public enum CallPreviewDismissal: Hashable, Sendable {
  /// At once.
  case immediate
  /// After showing its final state for this long. The system keeps an ended Live Activity for at
  /// most four hours.
  case after(Duration)
}
