import os

#if SWIFT_PACKAGE
  public import VoIPCore
#endif

/// The user's response to a call notification, such as a tap.
///
/// On iOS, create one from the `UNNotificationResponse` that the app's
/// `UNUserNotificationCenterDelegate` receives, and route it with
/// ``CallNotifier/handle(_:)-(CallNotificationResponse)``.
public struct CallNotificationResponse: Hashable, Sendable {
  /// What the user did with the notification.
  public enum Action: Hashable, Sendable {
    /// The user opened the notification, usually by tapping it.
    case open
    /// The user chose the notification's Join action.
    case join
  }

  /// The call the notification is about.
  public var callID: CallID

  /// The party calling.
  public var caller: Party

  /// Whether the call includes video.
  public var hasVideo: Bool

  /// What the user did with the notification.
  public var action: Action

  /// Creates a response to a call notification.
  ///
  /// - Parameters:
  ///   - callID: The call the notification is about.
  ///   - caller: The party calling.
  ///   - hasVideo: Whether the call includes video.
  ///   - action: What the user did with the notification.
  public init(callID: CallID, caller: Party, hasVideo: Bool = false, action: Action) {
    self.callID = callID
    self.caller = caller
    self.hasVideo = hasVideo
    self.action = action
  }
}

/// A request from the system to call a party, such as from Recents or Siri.
///
/// On iOS, the system delivers it as an `INStartCallIntent` in an `NSUserActivity`; create one
/// from either, and route it with ``CallNotifier/handle(_:)-(StartCallRequest)``.
public struct StartCallRequest: Hashable, Sendable {
  /// The party to call.
  public var party: Party

  /// Whether the user asked for video.
  public var hasVideo: Bool

  /// Creates a request to call a party.
  ///
  /// - Parameters:
  ///   - party: The party to call.
  ///   - hasVideo: Whether the user asked for video.
  public init(party: Party, hasVideo: Bool = false) {
    self.party = party
    self.hasVideo = hasVideo
  }
}

/// Where a response to a call notification, or a request to call a party, leads.
public enum CallNotificationRoute: Hashable, Sendable {
  /// The call is live in a call preview on this device, and the notifier requested to join it.
  ///
  /// The app places the join after `CallEvent.joinRequested`, as for any join.
  case joining(CallID)

  /// No call with the party is live in a call preview on this device.
  ///
  /// To call the party back, the app requests `Action.start` with a new Call ID of its own. For a
  /// ``StartCallRequest`` the user asked to call; for a ``CallNotificationResponse`` they opened a
  /// notification about a call that is over, and the app usually shows the party first.
  case callBack(Party, hasVideo: Bool)
}

extension CallNotifier {
  /// How long the notifier waits for the app to become active before it requests a join anyway.
  ///
  /// On an iPhone 13, the app became active about 0.6 and 0.7 seconds after it received the
  /// response to a call notification, and the system performed joins from a call preview's Lock
  /// Screen card 0.43 to 0.83 seconds after the tap. 2 seconds is more than twice the longest of
  /// these, and short enough that the user doesn't wait long for a join when the app stays
  /// inactive.
  static let activationLimit = Duration.seconds(2)

  private static let log = Logger(subsystem: "VoIPNotifications", category: "routing")

  /// Routes the user's response to a call notification.
  ///
  /// When the call is live in a call preview on this device, the notifier requests to join it for
  /// the Join action, and for a tap when ``Options/joinsOnTap`` is on. When the call is over, the
  /// route is to call the party back.
  ///
  /// The notifier requests the join once the app is active. A tap or the Join action brings the
  /// app to the foreground, and the system refuses a join that the app requests before it is
  /// active: on an iPhone 13, LiveCommunicationKit refused such joins with the call service's
  /// `com.apple.CallKit.error.requesttransaction` code 6, `invalidAction`. When the app isn't
  /// active yet, the notifier waits for it to become active, for up to 2 seconds, then requests
  /// the join anyway.
  ///
  /// Isolate the app's `UNUserNotificationCenterDelegate` and its conformance to the main actor.
  /// The system expects the completion handlers behind the delegate's `async` methods on the main
  /// thread, and stops the app when a delegate that isn't isolated to the main actor finishes one
  /// on another thread.
  ///
  /// ```swift
  /// @MainActor
  /// final class NotificationDelegate: NSObject, @MainActor UNUserNotificationCenterDelegate {
  ///   func userNotificationCenter(
  ///     _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ///   ) async {
  ///     guard let response = CallNotificationResponse(response) else { return }
  ///     if case .callBack(let party, let hasVideo)? = try? await notifier.handle(response) {
  ///       showCallBack(party, hasVideo: hasVideo)
  ///     }
  ///   }
  /// }
  /// ```
  ///
  /// It is unavailable in app extensions, which can't read the app's state.
  ///
  /// - Parameter response: The user's response to a call notification.
  /// - Returns: Where the response leads, or `nil` when the call is live here and nothing is to
  ///   be done: it is being joined or takes part already, or the user tapped the notification
  ///   with ``Options/joinsOnTap`` off.
  /// - Throws: The `ActionError` with which the client refused the join, for example because the
  ///   call ended meanwhile.
  @available(iOSApplicationExtension, unavailable)
  public func handle(
    _ response: CallNotificationResponse
  ) async throws(ActionError) -> CallNotificationRoute? {
    guard let client, let call = client.calls.first(where: { $0.id == response.callID }) else {
      return .callBack(response.caller, hasVideo: response.hasVideo)
    }
    guard case .previewing = call.status, response.action == .join || options.joinsOnTap else {
      return nil
    }
    await untilActive()
    try await client.request(.join(call.id))
    return .joining(call.id)
  }

  /// Routes the system's request to call a party.
  ///
  /// When a call with one of the party's handles is live in a call preview on this device, the
  /// notifier requests to join it, the newest first. Otherwise the route is to call the party.
  ///
  /// As for a response to a call notification, the notifier requests the join once the app is
  /// active, waiting for up to 2 seconds for it to become active.
  ///
  /// ```swift
  /// .onContinueUserActivity("INStartCallIntent") { activity in
  ///   guard let request = StartCallRequest(activity) else { return }
  ///   Task {
  ///     if case .callBack(let party, let hasVideo)? = try? await notifier.handle(request) {
  ///       try await client.request(
  ///         .start(OutgoingCall(id: CallID(rawValue: UUID().uuidString), parties: [party],
  ///           hasVideo: hasVideo)))
  ///     }
  ///   }
  /// }
  /// ```
  ///
  /// It is unavailable in app extensions, which can't read the app's state.
  ///
  /// - Parameter request: The request to call a party.
  /// - Returns: Where the request leads.
  /// - Throws: The `ActionError` with which the client refused the join, for example because the
  ///   call ended meanwhile.
  @available(iOSApplicationExtension, unavailable)
  public func handle(_ request: StartCallRequest) async throws(ActionError) -> CallNotificationRoute
  {
    let handles = Set(request.party.handles)
    let previewing = client?.calls.last { call in
      guard case .previewing = call.status else { return false }
      return call.parties.contains { !handles.isDisjoint(with: $0.handles) }
    }
    guard let client, let previewing else {
      return .callBack(request.party, hasVideo: request.hasVideo)
    }
    await untilActive()
    try await client.request(.join(previewing.id))
    return .joining(previewing.id)
  }

  /// Waits until the app is active, for up to ``activationLimit``.
  @available(iOSApplicationExtension, unavailable)
  private func untilActive() async {
    #if os(iOS)
      let activity = self.activity ?? ApplicationActivity()
    #else
      guard let activity else { return }
    #endif
    // Subscribing before reading the state leaves no gap in which an activation goes unseen.
    let activations = activity.activations()
    guard !activity.isActive else { return }
    await wait(for: activations, on: self.clock)
  }

  /// Waits for the first activation, for up to ``activationLimit``.
  private func wait(for activations: AsyncStream<Void>, on clock: some Clock<Duration>) async {
    let start = clock.now
    let limit = Self.activationLimit
    let becameActive = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        for await _ in activations { return true }
        return false
      }
      group.addTask {
        try? await clock.sleep(for: limit)
        return false
      }
      defer { group.cancelAll() }
      return await group.next() ?? false
    }
    let milliseconds = Int((start.duration(to: clock.now) / .milliseconds(1)).rounded())
    if becameActive {
      Self.log.info("The app became active after \(milliseconds) ms; requesting the join")
    } else {
      Self.log.notice("The app wasn't active after \(milliseconds) ms; requesting the join anyway")
    }
  }
}

/// What the notifier needs of the client to route the user's responses: its calls, and joining
/// one. `VoIPClient` is one; tests use another.
@MainActor
protocol NotifierClient: AnyObject {
  /// The calls on this device that haven't ended.
  var calls: [Call] { get }

  /// Requests an action on a call.
  func request(_ action: Action) async throws(ActionError)
}

extension VoIPClient: NotifierClient {}
