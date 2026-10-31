#if SWIFT_PACKAGE
  public import VoIPCore
  public import VoIPNotifications
#endif

/// A notification center that keeps call notifications as the system does, so that a
/// `CallNotifier` can be tested without UserNotifications.
///
/// Like the system, it keeps one notification for each call: posting one for a call that has one
/// replaces it.
@MainActor
public final class FakeCallNotificationCenter: CallNotificationCenter {
  /// Something the notifier asked of the center.
  public enum Record: Hashable, Sendable {
    /// The notifier posted a notification, whether the center accepted it or not.
    case post(CallNotification)
    /// The notifier withdrew a call's notification.
    case withdraw(CallID)
  }

  /// Everything the notifier asked of the center, in order.
  public private(set) var records: [Record] = []

  /// The notifications the center holds, in the order their calls were first posted.
  public private(set) var delivered: [CallNotification] = []

  /// The error with which the center refuses each post, or `nil` to accept it. Defaults to `nil`.
  public var postError: CallNotificationError?

  /// Creates a center that accepts every notification.
  public nonisolated init() {}

  // MARK: CallNotificationCenter

  /// Records the notification, then keeps it in place of any for the same call, or throws
  /// ``postError``.
  public func post(_ notification: CallNotification) async throws(CallNotificationError) {
    records.append(.post(notification))
    if let postError { throw postError }
    if let index = delivered.firstIndex(where: { $0.callID == notification.callID }) {
      delivered[index] = notification
    } else {
      delivered.append(notification)
    }
  }

  /// Records the withdrawal, and removes the call's notification.
  public func withdraw(_ id: CallID) async {
    records.append(.withdraw(id))
    delivered.removeAll { $0.callID == id }
  }
}
