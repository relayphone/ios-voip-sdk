import Foundation
import Observation
import UserNotifications
import VoIPAudio
import VoIPCore
import VoIPFocus
import VoIPLiveActivity
import VoIPLiveCommunicationKit
import VoIPNotifications
import VoIPPushKit
import VoIPSimulator

/// The app's real-time audio and video transport, such as WebRTC. This one does nothing.
@VoIPActor
final class NoMedia: CallMedia {
  nonisolated init() {}

  /// Connect to the call's room here, without using the microphone or speaker yet.
  func prepare(_ call: Call) async throws {}

  /// Start the microphone and speaker here: the system activated the audio session.
  func activate() {}

  /// Stop using the audio session here: the system deactivated it.
  func deactivate() {}
}

/// Starts the SDK when the app launches and turns the user's taps into actions.
@MainActor
@Observable
final class Calls {
  /// The SDK's client. Its `calls` hold every call that hasn't ended.
  let client: VoIPClient

  /// The audio session for calls. Its `routes` hold the audio routes the user can pick.
  let audio: AudioSessionAdapter

  /// Posts a call notification for each call that a Focus filters, and for each call that the app
  /// shows as a call preview, and routes the user's taps.
  let notifier = CallNotifier(
    options: CallNotifier.Options(triggers: [.filtered, .previewedByPolicy]))

  /// Passes the user's responses to call notifications to the notifier.
  private var notificationResponses: NotificationResponses?

  /// Shows call previews as Live Activities, and follows those the app's servers start.
  let previews = CallPreviewActivities()

  /// The VoIP push token, as hexadecimal, for the app's servers.
  private(set) var pushToken = "None yet"

  /// The push-to-start token, as hexadecimal, with which the app's servers start call previews.
  private(set) var pushToStartToken = "None yet"

  /// What happened to calls, newest first.
  private(set) var history: [String] = []

  /// What the Focus filter last asked for, which its extension records while the app may not be
  /// running.
  private(set) var focusFilterState: FocusFilterState<FocusSettings> = .unknown

  init() {
    // In Debug simulator builds, this presents calls in the iOS Simulator. Elsewhere it does
    // nothing.
    VoIPSimulator.activate()
    let push = PushKitSource()
    let audio = AudioSessionAdapter()
    self.audio = audio
    do {
      client = try VoIPClient.start(
        framework: LiveCommunicationKitAdapter(), media: NoMedia(), push: push, audio: audio,
        observers: [notifier, previews])
    } catch {
      fatalError("A process runs one VoIPClient: \(error)")
    }
    Task { [weak self] in
      // Send each token to your servers, which send this device's VoIP pushes.
      for await token in push.tokens() {
        self?.pushToken = token?.map { String(format: "%02x", $0) }.joined() ?? "Invalidated"
      }
    }
    let events = client.events()
    Task { [weak self] in
      for await event in events { await self?.handle(event) }
    }
    Task { [weak self] in
      // Send the state to your servers here too, as the extension may not have reached them.
      for await state in FocusSettings.store.states() {
        self?.focusFilterState = state
      }
    }
    Task { [previews, weak self] in
      // Send it to your servers with `previews.authorization`, so that they start call previews
      // only where the user allows Live Activities.
      for await token in previews.pushToStartTokens() {
        self?.pushToStartToken = token.map { String(format: "%02x", $0) }.joined()
      }
    }
    Task { [previews, weak self] in
      // Send each preview's push token to your servers, which update and end the preview with it.
      for await token in previews.pushTokens() {
        self?.history.insert("Preview push token for \(token.callID.rawValue)", at: 0)
      }
    }
    Task { [previews, weak self] in
      for await event in previews.events() {
        self?.history.insert("Live Activity: \(event)", at: 0)
      }
    }
    let notices = notifier.events()
    Task { [weak self] in
      for await notice in notices { self?.history.insert("Notification \(notice)", at: 0) }
    }
    // Set the delegate while the app launches, so that it receives the tap that launched the app.
    let responses = NotificationResponses(calls: self)
    UNUserNotificationCenter.current().delegate = responses
    notificationResponses = responses
  }

  /// Asks the user to allow notifications, and adds the call notification's category with its Join
  /// action.
  func allowNotifications() async {
    let center = UNUserNotificationCenter.current()
    center.setNotificationCategories([UserNotificationsAdapter.category()])
    do {
      let allowed = try await center.requestAuthorization(options: [.alert, .sound])
      history.insert("Notifications allowed: \(allowed)", at: 0)
    } catch {
      history.insert("Notifications not allowed: \(error)", at: 0)
    }
  }

  /// Presents an incoming call only as a call preview, which the notifier posts a notification
  /// for, as it does for a call that a Focus filters. In the foreground, the SDK also shows it as
  /// a Live Activity, from which the user can join.
  func previewIncomingCall() async {
    do {
      let caller = Party(
        handle: try Handle(kind: .phoneNumber, value: "+14155550123"), displayName: "Alice")
      let call = IncomingCall(
        id: CallID(rawValue: UUID().uuidString), parties: [caller],
        presentationPolicy: PresentationPolicy(incoming: .preview))
      let outcome = await client.report(call)
      history.insert("Reported: \(outcome)", at: 0)
    } catch {
      history.insert("Invalid caller: \(error)", at: 0)
    }
  }

  /// Joins the call of a tapped notification when it is live here.
  func respond(to response: CallNotificationResponse) async {
    do {
      switch try await notifier.handle(response) {
      case .joining(let id): history.insert("Joining \(id.rawValue)", at: 0)
      case .callBack(let party, _):
        // A notification of a call that is over: show the caller, from whom the user can call back.
        history.insert("Tapped a missed call from \(party.presentedHandle.value)", at: 0)
      case nil: break
      }
    } catch {
      history.insert("Couldn't join: \(error)", at: 0)
    }
  }

  /// Joins a call preview with the party, or calls the party, when the user calls from Recents or
  /// Siri.
  func start(_ request: StartCallRequest) async {
    do {
      guard
        case .callBack(let party, let hasVideo) = try await notifier.handle(request)
      else { return }
      let call = OutgoingCall(
        id: CallID(rawValue: UUID().uuidString), parties: [party], hasVideo: hasVideo)
      try await client.request(.start(call))
    } catch {
      history.insert("Couldn't call: \(error)", at: 0)
    }
  }

  /// Presents an incoming call, as a VoIP push from the app's servers would.
  func reportIncomingCall() async {
    do {
      let caller = Party(
        handle: try Handle(kind: .phoneNumber, value: "+14155550123"), displayName: "Alice")
      let call = IncomingCall(id: CallID(rawValue: UUID().uuidString), parties: [caller])
      let outcome = await client.report(call)
      history.insert("Reported: \(outcome)", at: 0)
    } catch {
      history.insert("Invalid caller: \(error)", at: 0)
    }
  }

  /// Asks the SDK to answer, end, mute or unmute a call.
  func request(_ action: Action) async {
    do {
      try await client.request(action)
    } catch {
      history.insert("Refused: \(error)", at: 0)
    }
  }

  /// Routes calls' audio to the route the user picked.
  func selectRoute(_ id: AudioRoute.ID) async {
    do {
      try await audio.selectRoute(id)
    } catch {
      history.insert("Route refused: \(error)", at: 0)
    }
  }

  private func handle(_ event: CallEvent) async {
    switch event {
    case .presented(let call): history.insert("Ringing: \(call.id.rawValue)", at: 0)
    case .previewStarted(let call): history.insert("Previewing: \(call.status)", at: 0)
    case .startRequested(let call), .joinRequested(let call):
      // The app places the call with its servers, then confirms it.
      await client.confirmPlaced(call.id)
    case .performed(let action, let call):
      history.insert("Performed \(action) → \(call.status)", at: 0)
      if case .answer(let id) = action {
        // Your servers tell the app when the call's media connects. This example connects at once.
        await client.receive(.connected, for: id, eventID: EventID(rawValue: UUID().uuidString))
      }
    case .audioActivated: history.insert("Audio activated", at: 0)
    case .audioDeactivated: history.insert("Audio deactivated", at: 0)
    case .audioInterrupted(let reason): history.insert("Audio interrupted: \(reason)", at: 0)
    case .mediaServicesReset: history.insert("Media services reset", at: 0)
    case .ended(let call): history.insert("Ended: \(call.status)", at: 0)
    }
  }
}

/// The app's notification center delegate, which passes the user's responses to call
/// notifications to the notifier.
final class NotificationResponses: NSObject, UNUserNotificationCenterDelegate {
  /// Weak, because the calls keep their delegate.
  private weak let calls: Calls?

  init(calls: Calls) {
    self.calls = calls
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    guard let response = CallNotificationResponse(response) else { return }  // Not a call's.
    await calls?.respond(to: response)
  }

  /// Shows notifications while the app is in the foreground too.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list, .sound]
  }
}
