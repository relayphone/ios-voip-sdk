#if os(iOS)
  public import Intents
  public import UserNotifications
  #if SWIFT_PACKAGE
    public import VoIPCore
  #endif

  /// Posts call notifications as communication notifications, with UserNotifications and Intents.
  ///
  /// The adapter is ``CallNotifier``'s default notification center on iOS. For each notification
  /// it donates an incoming `INInteraction` with an `INStartCallIntent` for the caller, then
  /// updates the notification's content from the intent, so that the system shows it as coming from
  /// the caller and a Focus lets it through for the people it allows. The caller is an `INPerson`
  /// made of the party's handles and display name only. A failed donation doesn't stop the
  /// notification.
  ///
  /// The notification's request identifier is the call's ID, so a later notification for the call
  /// replaces it. An incoming call's notification has the category ``categoryIdentifier``, with a
  /// Join action, and its `userInfo` carries the call so that
  /// `CallNotificationResponse.init(_:)` can read the user's response.
  ///
  /// ## Requirements
  ///
  /// - The Communication Notifications capability: the
  ///   `com.apple.developer.usernotifications.communication` entitlement, set to `true`.
  /// - `INStartCallIntent` in the `NSUserActivityTypes` array of the Info.plist of the app, and of
  ///   a notification service extension that builds call notifications.
  /// - The user's permission for notifications, which the app asks for with
  ///   `UNUserNotificationCenter.requestAuthorization(options:)`. Without it, posts throw
  ///   ``CallNotificationError/notAuthorized``. The SDK never asks.
  /// - For the Join action, the app adds ``category(joinTitle:)`` to its notification categories.
  ///
  /// The Time Sensitive Notifications capability, Contacts and Siri aren't needed: the SDK never
  /// posts a time-sensitive notification (see ADR 0009).
  ///
  /// ## In a notification service extension
  ///
  /// When the app's servers send a call notification as an alert push, the extension builds the
  /// same content with ``content(for:updating:)``. Set the push's `apns-collapse-id` to the call's
  /// ID, so that a notification that the app posts later for the call replaces the one from the
  /// push:
  ///
  /// ```swift
  /// override func didReceive(
  ///   _ request: UNNotificationRequest,
  ///   withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  /// ) {
  ///   // The app reads the call and its caller from its own push payload.
  ///   guard let notification = CallPush(request.content.userInfo)?.notification else {
  ///     return contentHandler(request.content)
  ///   }
  ///   Task {
  ///     let content = try? await UserNotificationsAdapter().content(
  ///       for: notification, updating: request.content)
  ///     contentHandler(content ?? request.content)
  ///   }
  /// }
  /// ```
  public struct UserNotificationsAdapter: CallNotificationCenter {
    /// The category identifier of an incoming call's notification.
    public static let categoryIdentifier = "VoIPNotifications.call"

    /// The identifier of the Join action in ``category(joinTitle:)``.
    public static let joinActionIdentifier = "VoIPNotifications.join"

    /// Returns the category of an incoming call's notification, with a Join action that opens the
    /// app.
    ///
    /// `UNUserNotificationCenter.setNotificationCategories(_:)` replaces every category, so add
    /// this one to the app's own:
    ///
    /// ```swift
    /// let center = UNUserNotificationCenter.current()
    /// center.setNotificationCategories(
    ///   appCategories.union([UserNotificationsAdapter.category()]))
    /// ```
    ///
    /// - Parameter joinTitle: The Join action's title, localized by the app.
    /// - Returns: The category.
    public static func category(joinTitle: String = "Join") -> UNNotificationCategory {
      UNNotificationCategory(
        identifier: categoryIdentifier,
        actions: [
          UNNotificationAction(
            identifier: joinActionIdentifier, title: joinTitle, options: .foreground)
        ],
        intentIdentifiers: [], options: [])
    }

    /// Creates an adapter for the app's notification center.
    public init() {}

    /// Posts a call notification as a communication notification, replacing any for the same
    /// call.
    ///
    /// - Parameter notification: The notification to post.
    /// - Throws: ``CallNotificationError/notAuthorized`` when the user hasn't allowed the app's
    ///   notifications, ``CallNotificationError/intentRejected`` when the system didn't make it a
    ///   communication notification, or ``CallNotificationError/postFailed`` when the system
    ///   refused it.
    public func post(_ notification: CallNotification) async throws(CallNotificationError) {
      let center = UNUserNotificationCenter.current()
      switch await center.notificationSettings().authorizationStatus {
      case .authorized, .provisional, .ephemeral: break
      default: throw .notAuthorized
      }
      let content = try await content(for: notification)
      let request = UNNotificationRequest(
        identifier: notification.callID.rawValue, content: content, trigger: nil)
      do {
        try await center.add(request)
      } catch {
        throw .postFailed
      }
    }

    /// Removes a call's notification, whether delivered or not yet.
    ///
    /// - Parameter id: The call whose notification to remove.
    public func withdraw(_ id: CallID) async {
      let center = UNUserNotificationCenter.current()
      center.removePendingNotificationRequests(withIdentifiers: [id.rawValue])
      center.removeDeliveredNotifications(withIdentifiers: [id.rawValue])
    }

    /// Makes the content of a call notification, as ``post(_:)`` posts it.
    ///
    /// Use it in a notification service extension, with the content of the push it received.
    /// The content keeps the push's other fields, including its `userInfo` entries.
    ///
    /// - Parameters:
    ///   - notification: The call notification.
    ///   - base: The content to update, such as the push's. Defaults to empty content.
    /// - Returns: The communication notification's content.
    /// - Throws: ``CallNotificationError/intentRejected`` when the system didn't make it a
    ///   communication notification.
    public func content(
      for notification: CallNotification,
      updating base: UNNotificationContent = UNNotificationContent()
    ) async throws(CallNotificationError) -> UNNotificationContent {
      let content = Self.baseContent(for: notification, updating: base)
      let intent = INStartCallIntent(notification)
      let interaction = INInteraction(intent: intent, response: nil)
      interaction.direction = .incoming
      // Donating only helps the system suggest the caller; the notification doesn't depend on it.
      try? await interaction.donate()
      do {
        return try content.updating(from: intent)
      } catch {
        throw .intentRejected
      }
    }

    /// The content before the intent updates it.
    static func baseContent(
      for notification: CallNotification, updating base: UNNotificationContent
    ) -> UNMutableNotificationContent {
      let content =
        base.mutableCopy() as? UNMutableNotificationContent ?? UNMutableNotificationContent()
      let caller = notification.caller
      content.title = caller.displayName ?? caller.presentedHandle.value
      content.body = notification.body
      content.sound = notification.playsSound ? .default : nil
      content.interruptionLevel =
        switch notification.interruptionLevel {
        case .passive: .passive
        case .active: .active
        }
      content.threadIdentifier = caller.presentedHandle.value
      if notification.kind == .incoming { content.categoryIdentifier = categoryIdentifier }
      content.userInfo.merge(CallNotificationPayload(notification).userInfo) { _, payload in payload
      }
      return content
    }
  }

  extension CallNotifier {
    /// Creates a notifier that posts with ``UserNotificationsAdapter``.
    ///
    /// - Parameter options: How the notifier chooses and makes notifications.
    public convenience init(options: Options = Options()) {
      self.init(options: options, center: UserNotificationsAdapter())
    }
  }

  extension CallNotificationResponse {
    /// Reads the user's response to a call notification, or returns `nil` for another
    /// notification, or for an action that isn't the notification's default action or Join.
    ///
    /// - Parameter response: The response that the app's `UNUserNotificationCenterDelegate`
    ///   received.
    public init?(_ response: UNNotificationResponse) {
      let action: Action
      switch response.actionIdentifier {
      case UNNotificationDefaultActionIdentifier: action = .open
      case UserNotificationsAdapter.joinActionIdentifier: action = .join
      default: return nil
      }
      self.init(userInfo: response.notification.request.content.userInfo, action: action)
    }
  }

  extension StartCallRequest {
    /// Reads a request to call a party from a user activity, or returns `nil` when it doesn't
    /// hold an `INStartCallIntent` with a contact.
    ///
    /// - Parameter activity: The activity that the system continues the app with.
    public init?(_ activity: NSUserActivity) {
      guard let intent = activity.interaction?.intent as? INStartCallIntent else { return nil }
      self.init(intent)
    }

    /// Reads a request to call a party from an intent, or returns `nil` when the intent has no
    /// contact with a handle.
    ///
    /// The first contact is the party. A phone number that isn't in E.164 format, as Siri may
    /// give it from the user's contacts, becomes a generic handle with the same value; the SDK
    /// doesn't reformat numbers.
    ///
    /// - Parameter intent: The intent.
    public init?(_ intent: INStartCallIntent) {
      guard let party = intent.contacts?.first.flatMap(Party.init(person:)) else { return nil }
      self.init(party: party, hasVideo: intent.callCapability == .videoCall)
    }
  }

  extension INStartCallIntent {
    /// An intent for an incoming call notification, with the caller as its only contact.
    convenience init(_ notification: CallNotification) {
      self.init(
        callRecordFilter: nil, callRecordToCallBack: nil, audioRoute: .unknown,
        destinationType: .normal, contacts: [INPerson(notification.caller)],
        callCapability: notification.hasVideo ? .videoCall : .audioCall)
    }
  }

  extension INPerson {
    /// A person made of a party's handles and display name only: the shape that a Focus matched
    /// by handle when measured on iOS 27.1.
    convenience init(_ party: Party) {
      let aliases = party.handles.dropFirst().map(INPersonHandle.init)
      self.init(
        personHandle: INPersonHandle(party.presentedHandle), nameComponents: nil,
        displayName: party.displayName, image: nil, contactIdentifier: nil,
        customIdentifier: party.presentedHandle.value, aliases: aliases.isEmpty ? nil : aliases,
        suggestionType: .none)
    }
  }

  extension INPersonHandle {
    /// The person handle for a handle. A generic handle has the unknown type.
    convenience init(_ handle: Handle) {
      let type: INPersonHandleType =
        switch handle.kind {
        case .phoneNumber: .phoneNumber
        case .emailAddress: .emailAddress
        case .generic: .unknown
        }
      self.init(value: handle.value, type: type)
    }
  }

  extension Party {
    /// The party for a person, from its handle, its aliases and its display name, or `nil` when
    /// it has no handle with a value.
    ///
    /// A person without a name reports one of its handles as its display name, a phone number
    /// formatted, so a display name that is only a handle isn't kept.
    init?(person: INPerson) {
      let personHandles = [person.personHandle].compactMap { $0 } + (person.aliases ?? [])
      let handles = personHandles.compactMap(Handle.init(personHandle:))
      let name = person.displayName
      let isHandle = handles.contains { $0.value == name || $0.isPhoneNumber(formattedAs: name) }
      let displayName = name.isEmpty || isHandle ? nil : name
      guard let party = try? Party(handles: handles, displayName: displayName) else { return nil }
      self = party
    }
  }

  extension Handle {
    /// Whether the handle is a phone number, and the text is that number with only formatting
    /// added, such as `+1 (415) 555-0123`.
    fileprivate func isPhoneNumber(formattedAs text: String) -> Bool {
      guard kind == .phoneNumber else { return false }
      let formatting = text.allSatisfy {
        ($0.isASCII && ($0.isNumber || "+()-.".contains($0))) || $0.isWhitespace
      }
      return formatting && text.filter(\.isNumber) == value.filter(\.isNumber)
    }

    /// The handle for a person handle, or `nil` when it has no value.
    init?(personHandle: INPersonHandle) {
      guard let value = personHandle.value else { return nil }
      let kind: Kind =
        switch personHandle.type {
        case .phoneNumber: .phoneNumber
        case .emailAddress: .emailAddress
        default: .generic
        }
      if let handle = try? Handle(kind: kind, value: value) {
        self = handle
      } else if let handle = try? Handle(kind: .generic, value: value) {
        self = handle
      } else {
        return nil
      }
    }
  }
#endif
