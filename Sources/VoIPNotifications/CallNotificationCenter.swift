#if SWIFT_PACKAGE
  public import VoIPCore
#endif

/// Where ``CallNotifier`` posts call notifications: the system's notification center, or a fake in
/// tests.
///
/// The center keeps at most one notification for each call. Posting one for a call that already
/// has one replaces it.
public protocol CallNotificationCenter: Sendable {
  /// Posts a call notification, replacing any that the center holds for the same call.
  ///
  /// - Parameter notification: The notification to post.
  /// - Throws: ``CallNotificationError`` when the notification couldn't be posted.
  func post(_ notification: CallNotification) async throws(CallNotificationError)

  /// Removes the notification for a call, whether the user has seen it or not. It does nothing
  /// when the center holds none.
  ///
  /// - Parameter id: The call whose notification to remove.
  func withdraw(_ id: CallID) async
}

/// Why a call notification couldn't be posted.
public enum CallNotificationError: Error, Hashable, Sendable {
  /// The user hasn't allowed the app's notifications. The app asks for authorization; the SDK
  /// never does.
  case notAuthorized
  /// The system didn't accept the call's intent for a communication notification, usually because
  /// the app lacks the Communication Notifications capability or doesn't list
  /// `INStartCallIntent` in `NSUserActivityTypes`.
  case intentRejected
  /// The system refused the notification.
  case postFailed
}
