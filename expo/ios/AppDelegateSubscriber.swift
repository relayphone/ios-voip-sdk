public import ExpoModulesCore
public import UIKit

/// Starts the SDK's client when the app launches, before JavaScript runs, and passes the system's
/// requests to call someone on to JavaScript.
///
/// Starting at launch registers for VoIP pushes, so a push that launched the app is reported, and
/// the SDK answers natively while JavaScript loads.
public final class VoIPConversationsAppDelegateSubscriber: ExpoAppDelegateSubscriber {
  public func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    CallService.shared.start()
    return true
  }

  /// Passes a request to call someone from Recents, Siri or Contacts to the module, which
  /// delivers it as a `dialRequest` conversation event, or, with call notifications, joins the
  /// party's call preview.
  public func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([any UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    defer { restorationHandler(nil) }
    return CallService.shared.continueCall(userActivity)
  }
}
