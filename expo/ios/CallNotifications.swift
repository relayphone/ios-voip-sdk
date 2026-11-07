#if VOIP_CONVERSATIONS_NOTIFICATIONS
  internal import ExpoNotifications
  import Foundation
  import UserNotifications
  import os

  /// Call notifications, with the `callNotifications` plugin option: the SDK's `CallNotifier`
  /// posts a communication notification for each call that Do Not Disturb or a Focus filtered,
  /// and this routes the user's responses to them.
  ///
  /// expo-notifications is the notification center's delegate in an Expo app, so the responses
  /// arrive through its `NotificationCenterManager`, natively and before JavaScript loads. The
  /// notifier joins a call that is live in a call preview; JavaScript learns where each response
  /// led from a `callNotificationRoute` conversation event, and what happened to each notification
  /// from a `callNotification` event.
  @MainActor
  final class CallNotifications {
    private static let log = Logger(subsystem: "VoIPConversations", category: "notifications")

    /// The observer that the client attaches as it starts.
    let notifier = CallNotifier()

    private let emit: @MainActor (String, JSONValue) -> Void
    private let deliver: @MainActor (String, JSONValue) -> Void
    private var responses: ResponseObserver?
    private var events: Task<Void, Never>?

    /// Creates the call notifications.
    ///
    /// - Parameters:
    ///   - emit: Sends a conversation event's type and payload to JavaScript.
    ///   - deliver: Sends a conversation event that waits for a listener, for one that the user's
    ///     response caused.
    init(
      emit: @escaping @MainActor (String, JSONValue) -> Void,
      deliver: @escaping @MainActor (String, JSONValue) -> Void
    ) {
      self.emit = emit
      self.deliver = deliver
    }

    /// Adds the Join action's category, follows the notifier's notifications, and starts
    /// receiving responses. The service calls it once, before it starts the client.
    func start() {
      guard responses == nil else { return }
      addCategory()
      let notifications = notifier.events()
      events = Task { [weak self] in
        for await event in notifications { self?.emit("callNotification", event.json) }
      }
      let responses = ResponseObserver { [weak self] response in
        Task { await self?.route(response) }
      }
      self.responses = responses
      NotificationCenterManager.shared.addDelegate(responses)
    }

    /// Routes the system's request to call a party, from Recents or Siri: the notifier joins a
    /// call with the party that is live in a call preview.
    ///
    /// - Returns: The party to call, unless the notifier joins its call preview. When the join
    ///   fails, for example because the call ended meanwhile, the party is called instead.
    func route(_ request: StartCallRequest) async -> (party: Party, hasVideo: Bool)? {
      do {
        switch try await notifier.handle(request) {
        case .callBack(let party, let hasVideo): return (party, hasVideo)
        case .joining: return nil
        }
      } catch {
        Self.log.error("Couldn't join the call preview: \(String(describing: error))")
        return (request.party, request.hasVideo)
      }
    }

    /// Routes the user's response to a call notification, and tells JavaScript where it led.
    private func route(_ response: CallNotificationResponse) async {
      let route: CallNotificationRoute?
      do {
        route = try await notifier.handle(response)
      } catch {
        Self.log.error("Couldn't join the call preview: \(String(describing: error))")
        return
      }
      guard let route else { return }
      deliver("callNotificationRoute", route.json)
    }

    /// Adds the category of an incoming call's notification, with its Join action, unless the
    /// app added one with the same identifier, for example to localize the action's title.
    private func addCategory() {
      let center = UNUserNotificationCenter.current()
      Task {
        let categories = await center.notificationCategories()
        let identifier = UserNotificationsAdapter.categoryIdentifier
        guard !categories.contains(where: { $0.identifier == identifier }) else { return }
        center.setNotificationCategories(categories.union([UserNotificationsAdapter.category()]))
      }
    }
  }

  /// Receives the user's responses to notifications from expo-notifications, and passes on those
  /// to call notifications.
  ///
  /// It doesn't claim the responses, so expo-notifications still delivers them to the app's own
  /// listeners.
  private final class ResponseObserver: NotificationDelegate, Sendable {
    private let receive: @Sendable (CallNotificationResponse) -> Void

    init(receive: @escaping @Sendable (CallNotificationResponse) -> Void) {
      self.receive = receive
    }

    func didReceive(
      _ response: UNNotificationResponse, completionHandler: @escaping () -> Void
    ) -> Bool {
      if let response = CallNotificationResponse(response) { receive(response) }
      return false
    }
  }

  extension CallNotifier.Event {
    /// The TypeScript API's `CallNotificationEvent`.
    fileprivate var json: JSONValue {
      switch self {
      case .posted(let notification):
        notification.json(type: "posted")
      case .withdrawn(let id):
        .object(["type": .string("withdrawn"), "conversationId": .string(id.rawValue)])
      case .failed(let notification, let error):
        notification.json(type: "failed", error: error)
      }
    }
  }

  extension CallNotification {
    fileprivate func json(type: String, error: CallNotificationError? = nil) -> JSONValue {
      var fields: [String: JSONValue] = [
        "type": .string(type),
        "conversationId": .string(callID.rawValue),
        "kind": .string(kind == .incoming ? "incoming" : "missed"),
        "caller": caller.participant,
        "video": .bool(hasVideo),
      ]
      if let error { fields["error"] = error.json }
      return .object(fields)
    }
  }

  extension CallNotificationError {
    /// The TypeScript API's `CallNotificationError`.
    fileprivate var json: JSONValue {
      switch self {
      case .notAuthorized: .string("notAuthorized")
      case .intentRejected: .string("intentRejected")
      case .postFailed: .string("postFailed")
      }
    }
  }

  extension CallNotificationRoute {
    /// The TypeScript API's `CallNotificationRoute`.
    fileprivate var json: JSONValue {
      switch self {
      case .joining(let id):
        .object(["type": .string("joining"), "conversationId": .string(id.rawValue)])
      case .callBack(let party, let hasVideo):
        .object([
          "type": .string("callBack"), "caller": party.participant, "video": .bool(hasVideo),
        ])
      }
    }
  }
#endif
