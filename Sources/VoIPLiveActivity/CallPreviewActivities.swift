public import Foundation
public import Observation

#if SWIFT_PACKAGE
  public import VoIPCore
#endif

/// Shows the client's call previews as Live Activities, and follows the ones that the app's
/// servers start.
///
/// Create it when the app launches and pass it to `VoIPClient.start` as an observer, so that it
/// follows calls from the first event:
///
/// ```swift
/// let previews = CallPreviewActivities()
/// let client = try VoIPClient.start(
///   framework: LiveCommunicationKitAdapter(), media: AppMedia(), push: PushKitSource(),
///   observers: [previews])
/// ```
///
/// When a call becomes a call preview while the app is in the foreground, the observer starts a
/// Live Activity for it. The system lets an app start a Live Activity only in the foreground, so
/// in the background the observer sends ``Event/startFailed(_:_:)`` with
/// ``CallPreviewError/notInForeground``, and the app's servers start the preview with the
/// device's push-to-start token instead, as `docs/call-preview-activity.md` describes. The
/// observer follows those Live Activities too, and gives each one's push token to the app.
///
/// The observer ends a preview's Live Activity at once when this device joins its call, because
/// the system's call screen takes over, and shows the final state for
/// ``Options/endedDismissal`` when the call ends. It keeps one Live Activity per call: when the
/// servers start a second, it ends the newer one at once.
///
/// The Join button of ``CallPreviewView`` performs the app's ``JoinCallPreviewIntent``, which
/// calls ``join(_:)``. A preview that the servers started before the app ran has a call that the
/// client doesn't know yet, so joining creates the call in the client from the preview.
///
/// Send the app's servers everything they need to start, update and end call previews:
///
/// ```swift
/// Task {
///   for await token in previews.pushToStartTokens() {
///     await server.updateLiveActivityPushToStartToken(token, authorization: previews.authorization)
///   }
/// }
/// Task {
///   for await token in previews.pushTokens() {
///     await server.updateCallPreviewPushToken(token.token, for: token.callID)
///   }
/// }
/// ```
///
/// The system launches the app in the background to deliver the push token of a Live Activity
/// that the servers started, so create the observer as the app launches, with the client.
@MainActor
@Observable
public final class CallPreviewActivities: CallObserver {
  /// How the observer shows call previews.
  public struct Options: Sendable {
    /// Whether the observer starts a Live Activity for each new call preview, which it can do
    /// only while the app is in the foreground. Defaults to `true`.
    ///
    /// Without it, the observer still follows the Live Activities that the app starts with
    /// ``CallPreviewActivities/start(_:state:)`` or that its servers start.
    public var startsActivities: Bool

    /// How long the state that the observer shows stays current, after which the Live Activity
    /// shows that it is out of date unless the app or its servers update it. Defaults to 2
    /// minutes.
    public var staleAfter: Duration

    /// How long a preview shows its final state once its call ended, before the system removes it
    /// from the Lock Screen. Defaults to 2 minutes.
    public var endedDismissal: Duration

    /// What a new call preview's Live Activity shows first. Defaults to
    /// ``defaultContent(for:)``.
    public var content: @Sendable (Call) -> CallPreviewAttributes.ContentState

    /// Creates the options for showing call previews.
    ///
    /// - Parameters:
    ///   - startsActivities: Whether the observer starts a Live Activity for each new call
    ///     preview.
    ///   - staleAfter: How long the state that the observer shows stays current.
    ///   - endedDismissal: How long a preview shows its final state once its call ended.
    ///   - content: What a new call preview's Live Activity shows first.
    public init(
      startsActivities: Bool = true,
      staleAfter: Duration = .seconds(120),
      endedDismissal: Duration = .seconds(120),
      content: @escaping @Sendable (Call) -> CallPreviewAttributes.ContentState =
        Options.defaultContent(for:)
    ) {
      self.startsActivities = startsActivities
      self.staleAfter = staleAfter
      self.endedDismissal = endedDismissal
      self.content = content
    }

    /// What a call preview's Live Activity shows by default: the preview's status, a timer from
    /// now, and Join.
    ///
    /// - Parameter call: The call that the preview shows.
    /// - Returns: The state with the call's ``CallPreviewStatus``, or ``CallPreviewStatus/policy``
    ///   for a call that isn't a call preview, starting now, without text, and joinable.
    public static func defaultContent(for call: Call) -> CallPreviewAttributes.ContentState {
      CallPreviewAttributes.ContentState(
        status: CallPreviewStatus(call.status) ?? .policy, startedAt: .now, isJoinable: true)
    }
  }

  /// Something that happened to a call preview's Live Activity.
  public enum Event: Hashable, Sendable {
    /// A Live Activity shows the call's preview: the observer or the app started it, or the app's
    /// servers did.
    case started(CallID)
    /// The observer couldn't start a Live Activity for the call. With
    /// ``CallPreviewError/notInForeground``, the app's servers can start it with the device's
    /// push-to-start token.
    case startFailed(CallID, CallPreviewError)
    /// The call's preview ended: this device joined the call, the call ended, or the app, the
    /// user, the system or the app's servers ended the Live Activity.
    case ended(CallID)
  }

  /// Whether the user allows the app's Live Activities, and their frequent updates.
  ///
  /// The SDK never asks: the system asks the user the first time one of the app's Live Activities
  /// appears. Read it to explain call previews before then, or to show that they are off.
  public private(set) var authorization: LiveActivityAuthorization

  private let options: Options
  private let center: any LiveActivityCenter
  @ObservationIgnored private weak var client: (any CallPreviewClient)?
  @ObservationIgnored private var previews: [CallID: Preview] = [:]
  /// The calls whose previews the observer follows, in the order their Live Activities started.
  @ObservationIgnored private var order: [CallID] = []
  @ObservationIgnored private var callIDs: [LiveActivityID: CallID] = [:]
  @ObservationIgnored private var pushToStartToken: Data?
  /// The calls that joining created in the client, which end with their previews.
  @ObservationIgnored private var adopted: Set<CallID> = []
  @ObservationIgnored private var listener: Task<Void, Never>?
  private let eventUpdates = Broadcast<Event>()
  private let pushTokenUpdates = Broadcast<CallPreviewPushToken>()
  private let pushToStartTokenUpdates = Broadcast<Data>()
  private let authorizationChanges = Broadcast<LiveActivityAuthorization>()

  /// A call preview's Live Activity that the observer follows.
  private struct Preview {
    let activity: LiveActivityID
    let attributes: CallPreviewAttributes
    var state: CallPreviewAttributes.ContentState
    var pushToken: Data?
  }

  /// Creates an observer that shows call previews in the given center of Live Activities.
  ///
  /// - Parameters:
  ///   - options: How the observer shows call previews.
  ///   - center: The system's Live Activities: ``ActivityKitAdapter`` in apps, a fake in tests.
  public init(options: Options = Options(), center: any LiveActivityCenter) {
    self.options = options
    self.center = center
    authorization = center.authorization
    center.attach { [weak self] event in self?.receive(event) }
  }

  #if os(iOS)
    /// Creates an observer that shows call previews with ActivityKit.
    ///
    /// - Parameter options: How the observer shows call previews.
    @available(iOSApplicationExtension, unavailable)
    public convenience init(options: Options = Options()) {
      self.init(options: options, center: ActivityKitAdapter())
    }
  #endif

  /// Returns a new stream of what happens to call previews' Live Activities.
  ///
  /// The stream starts with ``Event/started(_:)`` for each preview that a Live Activity shows,
  /// such as one that the app's servers started before the app ran, then yields each new event.
  public func events() -> AsyncStream<Event> {
    eventUpdates.stream(startingWith: order.map { .started($0) })
  }

  /// Returns a new stream of the push tokens of call previews' Live Activities, with which the
  /// app's servers update and end them.
  ///
  /// The stream starts with the token of each preview that has one, then yields each new token.
  /// It yields a `nil` token when a preview ends; stop sending its pushes then.
  ///
  /// The system gives the first preview that the app's servers start a token only once the user
  /// answers the system's second question about the app's Live Activities, which can take
  /// minutes. Until then the servers can't update or end that preview.
  public func pushTokens() -> AsyncStream<CallPreviewPushToken> {
    pushTokenUpdates.stream(
      startingWith: order.compactMap { id in
        previews[id]?.pushToken.map { CallPreviewPushToken(callID: id, token: $0) }
      })
  }

  /// Returns a new stream of the device's push-to-start token, with which the app's servers
  /// start call previews.
  ///
  /// The stream starts with the current token, when the system has issued one, then yields each
  /// new token.
  public func pushToStartTokens() -> AsyncStream<Data> {
    pushToStartTokenUpdates.stream(startingWith: pushToStartToken.map { [$0] } ?? [])
  }

  /// Returns a new stream of ``authorization``, starting with its current value.
  public func authorizationUpdates() -> AsyncStream<LiveActivityAuthorization> {
    authorizationChanges.stream(startingWith: [authorization])
  }

  /// Starts a Live Activity that previews a call, unless one already does.
  ///
  /// The observer calls it for each new call preview while ``Options/startsActivities`` is on.
  /// Call it to preview a call yourself, for example one that rings on another device. The state
  /// stays current for ``Options/staleAfter``. A failure is also sent as
  /// ``Event/startFailed(_:_:)``.
  ///
  /// - Parameters:
  ///   - call: The call to preview.
  ///   - state: What the Live Activity shows first, or `nil` for ``Options/content``.
  /// - Throws: ``CallPreviewError/activitiesDisabled`` when the user turned Live Activities
  ///   off, ``CallPreviewError/notInForeground`` when the app isn't in the foreground,
  ///   ``CallPreviewError/tooLarge`` when the attributes and state exceed the system's 4 KB, or
  ///   ``CallPreviewError/refused`` when the system refuses for another reason, such as too many
  ///   Live Activities.
  public func start(_ call: Call, state: CallPreviewAttributes.ContentState? = nil)
    throws(CallPreviewError)
  {
    guard previews[call.id] == nil else { return }
    let attributes = CallPreviewAttributes(call)
    let state = state ?? options.content(call)
    do throws(CallPreviewError) {
      guard center.authorization.areActivitiesEnabled else { throw .activitiesDisabled }
      guard attributes.fits(with: state) else { throw .tooLarge }
      let activity = try center.request(attributes, state: state, staleAfter: options.staleAfter)
      follow(activity, attributes, state)
    } catch {
      eventUpdates.send(.startFailed(call.id, error))
      throw error
    }
  }

  /// Changes what a call preview's Live Activity shows, from the app.
  ///
  /// The state stays current for ``Options/staleAfter``. While the app is in the background, its
  /// servers update the preview with its push token instead.
  ///
  /// - Parameters:
  ///   - id: The call whose preview to update.
  ///   - state: What the preview shows now.
  /// - Throws: ``CallPreviewError/notStarted`` when no Live Activity previews the call, or
  ///   ``CallPreviewError/tooLarge`` when the attributes and state exceed the system's 4 KB.
  public func update(_ id: CallID, _ state: CallPreviewAttributes.ContentState)
    async
    throws(CallPreviewError)
  {
    guard let preview = previews[id] else { throw .notStarted }
    guard preview.attributes.fits(with: state) else { throw .tooLarge }
    previews[id]?.state = state
    await center.update(preview.activity, state: state, staleAfter: options.staleAfter)
  }

  /// Ends a call preview's Live Activity, showing that its call ended until the system removes it.
  ///
  /// The observer ends previews itself when this device joins their call or the call ends. Ending
  /// a preview leaves its call as it is, unless joining created the call in the client, which
  /// then ends it.
  ///
  /// - Parameters:
  ///   - id: The call whose preview to end. Nothing happens when no Live Activity previews it.
  ///   - dismissal: When the system removes the Live Activity from the Lock Screen.
  public func end(_ id: CallID, dismissal: CallPreviewDismissal = .immediate) async {
    guard let preview = previews[id] else { return }
    await finish(id, state: Self.ended(preview.state), dismissal: dismissal)
  }

  /// Joins a call from its preview on this device, as the preview's Join button does.
  ///
  /// The client asks the app to place the join with `CallEvent.joinRequested(_:)`, as for any
  /// join, and the observer ends the preview's Live Activity once the call joined. A call that
  /// the client doesn't know, because the app's servers started its preview before the app ran,
  /// is joined with `VoIPClient.join(_:)` from the Live Activity's attributes: the client creates
  /// it without `CallEvent.previewStarted(_:)`, so that a call notifier posts nothing for a join
  /// that the user started. It ends when its preview ends without being joined.
  ///
  /// - Parameter id: The call to join.
  /// - Throws: ``CallPreviewError/notAttached`` when no client attached the observer,
  ///   ``CallPreviewError/unknownCall`` when neither the client nor a Live Activity knows the
  ///   call, or ``CallPreviewError/join(_:)`` when the client refuses the join, for example with
  ///   `ActionError.notAllowed(_:)` and the ended status of a call that the app's servers said
  ///   was over.
  public func join(_ id: CallID) async throws(CallPreviewError) {
    guard let client else { throw .notAttached }
    do throws(ActionError) {
      try await client.request(.join(id))
      return
    } catch .unknownCall {
      // The servers started the preview before the app ran.
    } catch {
      throw .join(error)
    }
    guard let attributes = previews[id]?.attributes else { throw .unknownCall }
    adopted.insert(id)
    do throws(ActionError) {
      try await client.join(
        IncomingCall(
          id: id, parties: attributes.parties, hasVideo: attributes.hasVideo,
          metadata: attributes.metadata,
          presentationPolicy: PresentationPolicy(incoming: .preview)))
    } catch {
      throw .join(error)
    }
  }

  /// The observer that the running client attached, whose ``join(_:)`` the Join intent calls.
  private(set) static weak var current: CallPreviewActivities?

  /// Joins a call with the observer that the running client attached.
  static func join(_ id: CallID) async throws(CallPreviewError) {
    guard let current else { throw .notAttached }
    try await current.join(id)
  }

  // MARK: CallObserver

  /// Starts following the client's calls.
  ///
  /// `VoIPClient.start` calls it once, before any call event; don't call it yourself.
  ///
  /// - Parameter client: The client that is starting.
  public func attach(to client: VoIPClient) {
    attach(client as any CallPreviewClient)
  }

  /// Starts following a client's calls.
  func attach(_ client: any CallPreviewClient) {
    self.client = client
    Self.current = self
    let events = client.events()
    listener = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        await self.handle(event)
      }
    }
  }

  // MARK: Calls

  private func handle(_ event: CallEvent) async {
    switch event {
    case .previewStarted(let call):
      guard previews[call.id] == nil else { return }
      if adopted.contains(call.id) {
        // A join that failed after the preview ended returns to a preview that nothing shows.
        try? await client?.request(.end(call.id))
      } else if options.startsActivities {
        // A failure is sent as an event.
        try? start(call)
      }
    case .performed(.join(let id), _):
      adopted.remove(id)
      // The system's call screen takes over from the preview.
      await finish(id, state: nil, dismissal: .immediate)
    case .ended(let call):
      adopted.remove(call.id)
      guard let preview = previews[call.id] else { return }
      await finish(
        call.id, state: Self.ended(preview.state), dismissal: .after(options.endedDismissal))
    default:
      break
    }
  }

  /// Stops following a call's preview, and ends its Live Activity.
  private func finish(
    _ id: CallID, state: CallPreviewAttributes.ContentState?, dismissal: CallPreviewDismissal
  ) async {
    guard let preview = forget(id) else { return }
    await center.end(preview.activity, state: state, dismissal: dismissal)
    eventUpdates.send(.ended(id))
    await endAdopted(id)
  }

  /// Ends a call that joining created in the client, once its preview ended without a join.
  private func endAdopted(_ id: CallID) async {
    guard adopted.contains(id) else { return }
    try? await client?.request(.end(id))
  }

  /// Stops following a call's preview, and tells the app that its push token is gone.
  private func forget(_ id: CallID) -> Preview? {
    guard let preview = previews.removeValue(forKey: id) else { return nil }
    order.removeAll { $0 == id }
    callIDs[preview.activity] = nil
    pushTokenUpdates.send(CallPreviewPushToken(callID: id, token: nil))
    return preview
  }

  /// The final state of a preview whose call ended.
  private static func ended(_ state: CallPreviewAttributes.ContentState)
    -> CallPreviewAttributes.ContentState
  {
    CallPreviewAttributes.ContentState(
      status: .ended, startedAt: state.startedAt, snippet: state.snippet, isJoinable: false)
  }

  // MARK: Live Activities

  private func receive(_ event: LiveActivityEvent) {
    switch event {
    case .started(let activity, let attributes, let state):
      follow(activity, attributes, state)
    case .pushTokenChanged(let activity, let token):
      guard let id = callIDs[activity] else { return }
      previews[id]?.pushToken = token
      pushTokenUpdates.send(CallPreviewPushToken(callID: id, token: token))
    case .ended(let activity):
      guard let id = callIDs[activity], forget(id) != nil else { return }
      eventUpdates.send(.ended(id))
      Task { await endAdopted(id) }
    case .pushToStartTokenChanged(let token):
      pushToStartToken = token
      pushToStartTokenUpdates.send(token)
    case .authorizationChanged(let authorization):
      self.authorization = authorization
      authorizationChanges.send(authorization)
    }
  }

  /// Follows a call preview's Live Activity, unless its call already has one, in which case the
  /// newer one ends at once.
  private func follow(
    _ activity: LiveActivityID, _ attributes: CallPreviewAttributes,
    _ state: CallPreviewAttributes.ContentState
  ) {
    guard callIDs[activity] == nil else { return }
    let id = attributes.callID
    if previews[id] != nil {
      Task { await center.end(activity, state: nil, dismissal: .immediate) }
      return
    }
    previews[id] = Preview(activity: activity, attributes: attributes, state: state)
    order.append(id)
    callIDs[activity] = id
    eventUpdates.send(.started(id))
  }
}

/// The push token of a call preview's Live Activity, with which the app's servers update and end
/// it.
public struct CallPreviewPushToken: Hashable, Sendable {
  /// The call that the Live Activity previews.
  public var callID: CallID

  /// The push token, or `nil` once the preview ended.
  public var token: Data?

  /// Creates a call preview's push token.
  ///
  /// - Parameters:
  ///   - callID: The call that the Live Activity previews.
  ///   - token: The push token, or `nil` once the preview ended.
  public init(callID: CallID, token: Data?) {
    self.callID = callID
    self.token = token
  }
}

/// Why a call preview's Live Activity couldn't start or change.
public enum CallPreviewError: Error, Hashable, Sendable {
  /// The user turned off the app's Live Activities, or the app doesn't support them.
  case activitiesDisabled
  /// The app isn't in the foreground, where the system lets it start a Live Activity. The app's
  /// servers can start the preview with the device's push-to-start token.
  case notInForeground
  /// The attributes and the state together exceed the system's 4 KB limit.
  case tooLarge
  /// The system refused for another reason, such as too many Live Activities at once.
  case refused
  /// No Live Activity previews the call.
  case notStarted
  /// Neither the client nor a Live Activity knows the call.
  case unknownCall
  /// No client attached the observer: create it as the app launches and pass it to
  /// `VoIPClient.start` as an observer.
  case notAttached
  /// The client refused to join the call.
  case join(ActionError)
}

/// What ``CallPreviewActivities`` needs of `VoIPClient`, so that tests can script it.
@MainActor
protocol CallPreviewClient: AnyObject {
  func events() -> AsyncStream<CallEvent>
  func request(_ action: Action) async throws(ActionError)
  func join(_ call: IncomingCall) async throws(ActionError)
}

extension VoIPClient: CallPreviewClient {}
