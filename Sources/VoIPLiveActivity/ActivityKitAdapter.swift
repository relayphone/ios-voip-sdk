#if os(iOS)
  // ActivityKit doesn't annotate `Activity` for Swift concurrency. The adapter keeps each one on
  // the main actor and calls only its own asynchronous methods, as ActivityKit expects.
  @preconcurrency import ActivityKit
  import Foundation
  import UIKit

  /// The system's Live Activities through ActivityKit.
  ///
  /// ``CallPreviewActivities`` uses one by default. It handles the app's Live Activities whose
  /// attributes are ``CallPreviewAttributes``: the ones it starts with a push token, and the ones
  /// the app's servers start with the push-to-start token, which ActivityKit reports when it
  /// launches the app in the background.
  ///
  /// The app declares `NSSupportsLiveActivities`, and `NSSupportsLiveActivitiesFrequentUpdates`
  /// for frequent updates, in its Info.plist, has the Push Notifications capability, and shows the
  /// Live Activities with a widget extension. Only the app uses the adapter: it reads the app's
  /// state, which app extensions can't.
  @MainActor
  @available(iOSApplicationExtension, unavailable)
  public final class ActivityKitAdapter: LiveActivityCenter {
    private let info = ActivityAuthorizationInfo()
    private var activities: [LiveActivityID: Activity<CallPreviewAttributes>] = [:]
    private var onEvent: (@MainActor (LiveActivityEvent) -> Void)?
    private var tasks: [Task<Void, Never>] = []
    private var activityTasks: [LiveActivityID: [Task<Void, Never>]] = [:]

    /// Creates an adapter for the system's Live Activities.
    public init() {}

    isolated deinit {
      for task in tasks + activityTasks.values.joined() { task.cancel() }
    }

    // MARK: LiveActivityCenter

    /// Whether the user allows the app's Live Activities, and their frequent updates.
    public var authorization: LiveActivityAuthorization {
      LiveActivityAuthorization(
        areActivitiesEnabled: info.areActivitiesEnabled,
        frequentPushesEnabled: info.frequentPushesEnabled)
    }

    /// Reports the running call previews' Live Activities, then follows ActivityKit's updates.
    public func attach(onEvent: @escaping @MainActor (LiveActivityEvent) -> Void) {
      guard self.onEvent == nil else { return }
      self.onEvent = onEvent
      for activity in Activity<CallPreviewAttributes>.activities { follow(activity) }
      if let token = Activity<CallPreviewAttributes>.pushToStartToken {
        onEvent(.pushToStartTokenChanged(token))
      }
      tasks = [
        Task { [weak self] in
          for await activity in Activity<CallPreviewAttributes>.activityUpdates {
            self?.follow(activity)
          }
        },
        Task { [weak self] in
          for await token in Activity<CallPreviewAttributes>.pushToStartTokenUpdates {
            self?.onEvent?(.pushToStartTokenChanged(token))
          }
        },
        Task { [weak self, info] in
          for await _ in info.activityEnablementUpdates { self?.authorizationChanged() }
        },
        Task { [weak self, info] in
          for await _ in info.frequentPushEnablementUpdates { self?.authorizationChanged() }
        },
      ]
    }

    /// Starts a Live Activity with `Activity.request(attributes:content:pushType:)` and a push
    /// token.
    ///
    /// In the background, where the system refuses, it throws ``CallPreviewError/notInForeground``
    /// without asking ActivityKit, which can block the main thread for seconds before it refuses.
    public func request(
      _ attributes: CallPreviewAttributes, state: CallPreviewAttributes.ContentState,
      staleAfter: Duration?
    ) throws(CallPreviewError) -> LiveActivityID {
      guard UIApplication.shared.applicationState != .background else { throw .notInForeground }
      let activity: Activity<CallPreviewAttributes>
      do {
        activity = try Activity.request(
          attributes: attributes, content: Self.content(state, staleAfter: staleAfter),
          pushType: .token)
      } catch let error as ActivityAuthorizationError {
        throw CallPreviewError(error)
      } catch {
        throw .refused
      }
      follow(activity)
      return LiveActivityID(rawValue: activity.id)
    }

    /// Updates a Live Activity's content.
    public func update(
      _ id: LiveActivityID, state: CallPreviewAttributes.ContentState, staleAfter: Duration?
    ) async {
      await activities[id]?.update(Self.content(state, staleAfter: staleAfter))
    }

    /// Ends a Live Activity with a dismissal policy.
    public func end(
      _ id: LiveActivityID, state: CallPreviewAttributes.ContentState?,
      dismissal: CallPreviewDismissal
    ) async {
      guard let activity = activities[id] else { return }
      let policy: ActivityUIDismissalPolicy =
        switch dismissal {
        case .immediate: .immediate
        case .after(let duration): .after(.now.addingTimeInterval(duration.timeInterval))
        }
      await activity.end(state.map { Self.content($0, staleAfter: nil) }, dismissalPolicy: policy)
      ended(id)
    }

    // MARK: Following

    private func follow(_ activity: Activity<CallPreviewAttributes>) {
      let id = LiveActivityID(rawValue: activity.id)
      guard activities[id] == nil, activity.activityState != .ended,
        activity.activityState != .dismissed
      else { return }
      activities[id] = activity
      onEvent?(.started(id, activity.attributes, activity.content.state))
      if let token = activity.pushToken { onEvent?(.pushTokenChanged(id, token)) }
      activityTasks[id] = [
        Task { [weak self] in
          for await token in activity.pushTokenUpdates {
            self?.onEvent?(.pushTokenChanged(id, token))
          }
        },
        Task { [weak self] in
          for await state in activity.activityStateUpdates
          where state == .ended || state == .dismissed {
            self?.ended(id)
            return
          }
        },
      ]
    }

    private func ended(_ id: LiveActivityID) {
      guard activities.removeValue(forKey: id) != nil else { return }
      for task in activityTasks.removeValue(forKey: id) ?? [] { task.cancel() }
      onEvent?(.ended(id))
    }

    private func authorizationChanged() {
      onEvent?(.authorizationChanged(authorization))
    }

    private static func content(
      _ state: CallPreviewAttributes.ContentState, staleAfter: Duration?
    ) -> ActivityContent<CallPreviewAttributes.ContentState> {
      ActivityContent(
        state: state, staleDate: staleAfter.map { .now.addingTimeInterval($0.timeInterval) })
    }
  }

  extension CallPreviewError {
    /// The error for an ActivityKit failure.
    init(_ error: ActivityAuthorizationError) {
      switch error {
      case .denied, .unsupported, .unentitled: self = .activitiesDisabled
      case .visibility: self = .notInForeground
      case .attributesTooLarge: self = .tooLarge
      default: self = .refused
      }
    }
  }

  extension Duration {
    /// The duration in seconds, as Foundation measures time.
    fileprivate var timeInterval: TimeInterval {
      Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
  }
#endif
