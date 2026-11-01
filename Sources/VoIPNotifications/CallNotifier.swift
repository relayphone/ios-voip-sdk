#if SWIFT_PACKAGE
  public import VoIPCore
#endif

/// Posts a communication notification for each call that Do Not Disturb or a Focus filtered, so
/// that the people a Focus allows still reach the user.
///
/// LiveCommunicationKit doesn't present a call that a Focus filters, even from a person the Focus
/// allows: the SDK keeps the call as a call preview, or ends it as filtered (see ADR 0005). A
/// communication notification about the call gets through instead. The system presents it for the
/// people the Focus allows, and adds it quietly to Notification Center for everyone else.
///
/// Create the notifier when the app launches, and pass it to
/// `VoIPClient.start(framework:media:push:audio:observers:configuration:clock:)` as an observer,
/// so that it sees the call of the VoIP push that cold-launched the app. On iOS it posts with
/// ``UserNotificationsAdapter`` by default:
///
/// ```swift
/// let notifier = CallNotifier()
/// let client = try VoIPClient.start(
///   framework: LiveCommunicationKitAdapter(), media: AppMedia(), push: PushKitSource(),
///   observers: [notifier])
/// ```
///
/// The app needs the Communication Notifications capability, `INStartCallIntent` in its
/// `NSUserActivityTypes`, and the user's permission for notifications; see
/// ``UserNotificationsAdapter``.
///
/// ## When it posts
///
/// The notifier posts one notification for a call, of kind ``CallNotification/Kind/incoming``:
///
/// - when the call becomes a call preview because Do Not Disturb or a Focus filtered it, with
///   reason `PreviewReason.filtered(.doNotDisturb)`;
/// - when the presentation policy shows the call as a call preview, with reason
///   `PreviewReason.policy`, if ``Options/triggers`` include ``Triggers/previewedByPolicy``.
///
/// When the presentation policy doesn't preview filtered calls, a call that Do Not Disturb or a
/// Focus filtered ends at once as `EndReason.filtered(.doNotDisturb)`. The notifier then posts only
/// what ``Options/endedWithoutJoining`` asks for: a missed-call notification by default.
///
/// It never posts for a call that rings, a call that the system filtered because the caller is on
/// the block list or without saying why, or a call answered elsewhere. Its notifications never
/// ring: their interruption level is passive or active, and their sound is the default or none
/// (see ADR 0009).
///
/// ## After it posts
///
/// - When the call is joined on this device, the notifier withdraws the call's notification,
///   unless ``Options/withdrawsWhenJoined`` is off.
/// - When the call ends without being joined on this device, the notifier replaces the
///   notification with a missed-call notification, of kind ``CallNotification/Kind/missed``.
///   ``Options/endedWithoutJoining`` can keep or remove it instead.
///
/// A call that the user tried to join counts as joined, even when the join failed, whether the
/// user joined from a notification, a call preview's Live Activity or the app: the notifier
/// withdraws its notification as for a join, and posts nothing more for the call. The call
/// returns to its preview without a new notification, and ends without a missed-call one.
///
/// Follow what happens to the notifications with ``events()``.
///
/// ## Routing the user's responses
///
/// Pass the responses to call notifications that the app's `UNUserNotificationCenterDelegate`
/// receives to ``handle(_:)-(CallNotificationResponse)``, and the `INStartCallIntent`s that the
/// system sends from Recents or Siri to ``handle(_:)-(StartCallRequest)``. When the call is live
/// in a call preview on this device, the notifier requests to join it once the app is active,
/// since the system refuses a join while the app is still coming to the foreground; otherwise the
/// route is to call the party back, which the app does with a Call ID of its own.
@MainActor
public final class CallNotifier: CallObserver {
  /// What makes the notifier post a notification for a call.
  public struct Triggers: OptionSet, Hashable, Sendable {
    /// Calls that Do Not Disturb or a Focus filtered, whether they become call previews or end.
    public static let filtered = Triggers(rawValue: 1 << 0)
    /// Calls that the presentation policy shows as call previews, with reason
    /// `PreviewReason.policy`, such as calls that an assistant answers first.
    public static let previewedByPolicy = Triggers(rawValue: 1 << 1)

    /// The triggers as a bit field.
    public let rawValue: Int

    /// Creates triggers from a bit field.
    public init(rawValue: Int) {
      self.rawValue = rawValue
    }
  }

  /// What the notifier does with a call's notification when the call ends without being joined
  /// on this device.
  public enum EndedCallNotification: Hashable, Sendable {
    /// Replace it with a missed-call notification, of kind ``CallNotification/Kind/missed``.
    case missedCall
    /// Leave it as it is.
    case keep
    /// Remove it.
    case remove
  }

  /// How the notifier chooses and makes notifications.
  public struct Options: Sendable {
    /// What makes the notifier post a notification for a call. Defaults to
    /// ``Triggers/filtered``.
    public var triggers: Triggers

    /// How the notifications interrupt the user, when the user's Focus lets them through.
    /// Defaults to ``CallNotification/InterruptionLevel/active``.
    public var interruptionLevel: CallNotification.InterruptionLevel

    /// Whether the notifications play the system's default notification sound. Defaults to
    /// `true`.
    public var playsSound: Bool

    /// Whether the notifier withdraws a call's notification when the call is joined on this
    /// device. Defaults to `true`.
    public var withdrawsWhenJoined: Bool

    /// Whether tapping the notification of a call that is live in a call preview joins the call,
    /// as its Join action does. Defaults to `true`.
    ///
    /// It applies to the responses that the app routes with
    /// ``CallNotifier/handle(_:)-(CallNotificationResponse)``.
    public var joinsOnTap: Bool

    /// Decides what happens to a call's notification when the call ends without being joined on
    /// this device. It receives the ended call, whose status holds the end reason. Defaults to
    /// ``EndedCallNotification/missedCall``.
    public var endedWithoutJoining: @MainActor (Call) -> EndedCallNotification

    /// Changes each notification before the notifier posts it, for example to localize its body
    /// or to name the caller as the app's contacts do.
    ///
    /// It receives the notification that the notifier made and the call, and returns the
    /// notification to post, or `nil` to post none. Keep the notification's call ID, so that a
    /// missed-call notification replaces the incoming one. Defaults to returning the notification
    /// unchanged.
    public var customize: @MainActor (CallNotification, Call) -> CallNotification?

    /// Creates options.
    ///
    /// - Parameters:
    ///   - triggers: What makes the notifier post a notification for a call.
    ///   - interruptionLevel: How the notifications interrupt the user.
    ///   - playsSound: Whether the notifications play the default notification sound.
    ///   - withdrawsWhenJoined: Whether the notifier withdraws a call's notification when the call
    ///     is joined on this device.
    ///   - joinsOnTap: Whether tapping the notification of a call that is live in a call preview
    ///     joins the call.
    ///   - endedWithoutJoining: Decides what happens to a call's notification when the call ends
    ///     without being joined on this device.
    ///   - customize: Changes each notification before the notifier posts it.
    public init(
      triggers: Triggers = .filtered,
      interruptionLevel: CallNotification.InterruptionLevel = .active,
      playsSound: Bool = true,
      withdrawsWhenJoined: Bool = true,
      joinsOnTap: Bool = true,
      endedWithoutJoining: @escaping @MainActor (Call) -> EndedCallNotification = { _ in
        .missedCall
      },
      customize: @escaping @MainActor (CallNotification, Call) -> CallNotification? = {
        notification, _ in notification
      }
    ) {
      self.triggers = triggers
      self.interruptionLevel = interruptionLevel
      self.playsSound = playsSound
      self.withdrawsWhenJoined = withdrawsWhenJoined
      self.joinsOnTap = joinsOnTap
      self.endedWithoutJoining = endedWithoutJoining
      self.customize = customize
    }
  }

  /// Something that happened to a call's notification.
  public enum Event: Hashable, Sendable {
    /// The notifier posted a notification, replacing any that it had posted for the same call.
    case posted(CallNotification)
    /// The notifier removed a call's notification.
    case withdrawn(CallID)
    /// The notification center couldn't post a notification.
    case failed(CallNotification, CallNotificationError)
  }

  /// How the notifier chooses and makes notifications.
  public let options: Options

  private let center: any CallNotificationCenter
  /// The client whose calls the notifier follows, which it keeps weakly so that the client can be
  /// released.
  private(set) weak var client: (any NotifierClient)?
  /// Whether the app is active, which a join waits for, or `nil` for the app's own state.
  let activity: (any NotifierAppActivity)?
  /// The clock that times the wait for the app to become active.
  let clock: any Clock<Duration>
  private let subscribers = NotifierEventStreams<Event>()
  /// The live calls the notifier made a notification for, or that the user tried to join.
  private var notified: [CallID: Notified] = [:]
  private var task: Task<Void, Never>?

  /// Creates a notifier.
  ///
  /// - Parameters:
  ///   - options: How the notifier chooses and makes notifications.
  ///   - center: Where the notifier posts notifications.
  public convenience init(options: Options = Options(), center: any CallNotificationCenter) {
    self.init(options: options, center: center, activity: nil, clock: ContinuousClock())
  }

  /// Creates a notifier that learns whether the app is active from `activity`, and times the wait
  /// for it with `clock`. Tests pass fakes.
  init(
    options: Options = Options(), center: any CallNotificationCenter,
    activity: (any NotifierAppActivity)?, clock: any Clock<Duration>
  ) {
    self.options = options
    self.center = center
    self.activity = activity
    self.clock = clock
  }

  /// Starts following the client's calls. The client calls it once, while it starts.
  ///
  /// A notifier follows one client at a time: attaching it to another stops following the
  /// previous one.
  ///
  /// - Parameter client: The client that is starting.
  public func attach(to client: VoIPClient) {
    follow(client.events(), client: client)
  }

  /// Returns a new stream of what happens to the notifier's notifications from now on.
  ///
  /// Each call returns a separate stream for one subscriber.
  public func events() -> AsyncStream<Event> {
    subscribers.stream()
  }

  /// Handles each call event in order, so that a notification is posted before it is replaced or
  /// withdrawn, and routes responses to the client.
  func follow(_ events: AsyncStream<CallEvent>, client: (any NotifierClient)? = nil) {
    task?.cancel()
    notified = [:]
    self.client = client
    task = Task { [weak self] in
      for await event in events {
        // A stream buffers events, which a cancelled task still receives.
        guard !Task.isCancelled, let self else { return }
        await self.handle(event)
      }
    }
  }

  private func handle(_ event: CallEvent) async {
    switch event {
    case .previewStarted(let call):
      // A call whose join failed returns to its preview, and keeps its notification.
      guard notified[call.id] == nil, case .previewing(let reason) = call.status,
        triggers(reason)
      else { return }
      notified[call.id] = Notified()
      notified[call.id]?.isPosted = await post(.incoming, for: call)
    case .performed(.join(let id), _):
      guard notified[id] != nil else { return }
      await joined(id)
    case .joinFailed(let call):
      // The user asked to join the call, so it isn't news to them: it returns to its preview and
      // ends without a notification.
      if notified[call.id] == nil { notified[call.id] = Notified() }
      await joined(call.id)
    case .ended(let call):
      if let entry = notified.removeValue(forKey: call.id) {
        guard !entry.isJoined else { return }
        switch options.endedWithoutJoining(call) {
        case .missedCall: await post(.missed, for: call)
        case .keep: break
        case .remove: if entry.isPosted { await withdraw(call.id) }
        }
      } else if call.status == .ended(.filtered(.doNotDisturb)),
        options.triggers.contains(.filtered)
      {
        // The policy doesn't preview filtered calls, so the call ended as soon as it was
        // filtered: post only what its notification would become.
        switch options.endedWithoutJoining(call) {
        case .missedCall: await post(.missed, for: call)
        case .keep: await post(.incoming, for: call)
        case .remove: break
        }
      }
    default:
      break
    }
  }

  /// Records that the user joined a call, or tried to, and withdraws its notification.
  private func joined(_ id: CallID) async {
    notified[id]?.isJoined = true
    if options.withdrawsWhenJoined, notified[id]?.isPosted == true {
      notified[id]?.isPosted = false
      await withdraw(id)
    }
  }

  private func triggers(_ reason: PreviewReason) -> Bool {
    switch reason {
    case .filtered(.doNotDisturb): options.triggers.contains(.filtered)
    case .policy: options.triggers.contains(.previewedByPolicy)
    case .filtered(.blockList), .filtered(.unspecified), .answeredElsewhere: false
    }
  }

  /// Makes and posts a call's notification.
  ///
  /// - Returns: Whether the center holds the notification now.
  @discardableResult
  private func post(_ kind: CallNotification.Kind, for call: Call) async -> Bool {
    guard let caller = call.parties.first else { return false }
    let made = CallNotification(
      callID: call.id, kind: kind, caller: caller, hasVideo: call.hasVideo,
      interruptionLevel: options.interruptionLevel, playsSound: options.playsSound)
    guard let notification = options.customize(made, call) else { return false }
    do {
      try await center.post(notification)
      subscribers.yield(.posted(notification))
      return true
    } catch {
      subscribers.yield(.failed(notification, error))
      return false
    }
  }

  private func withdraw(_ id: CallID) async {
    await center.withdraw(id)
    subscribers.yield(.withdrawn(id))
  }
}

/// A live call that the notifier made a notification for, or that the user tried to join.
private struct Notified {
  /// Whether the center holds the call's notification.
  var isPosted = false
  /// Whether the call was joined on this device, or the user tried to join it.
  var isJoined = false
}
