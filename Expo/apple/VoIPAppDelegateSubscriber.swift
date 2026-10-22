import ExpoModulesCore
import UIKit

/// Register native PushKit during app launch, including launches with no UI scene.
public final class VoIPAppDelegateSubscriber: ExpoAppDelegateSubscriber {
  public func appDelegateWillBeginInitialization() {
    do { _ = try VoIPApplication.startFromBundle() }
    catch { NSLog("[VoIPSDK] Could not register native VoIP services during app launch.") }
  }

  public func application(_ application: UIApplication,
                          didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                          fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    do {
      let owner = try VoIPApplication.startFromBundle()
      completionHandler(owner.pushService.receiveRemoteMessage(userInfo) ? .newData : .noData)
    } catch { completionHandler(.failed) }
  }
}
