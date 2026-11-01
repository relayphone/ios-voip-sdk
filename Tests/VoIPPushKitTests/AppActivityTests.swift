#if os(iOS)
  import Foundation
  import Testing
  import UIKit

  @testable import VoIPPushKit

  @Suite @MainActor struct AppActivityTests {
    private let center = NotificationCenter()

    @Test func theAppIsInactiveUntilUIKitSaysItBecameActive() {
      let activity = AppActivity(center: center)
      #expect(!activity.isActive)
      center.post(UIApplication.WillEnterForegroundMessage())
      #expect(!activity.isActive)
      center.post(UIApplication.DidBecomeActiveMessage())
      #expect(activity.isActive)
    }

    @Test func followsTheAppResigningAndBecomingActiveAgain() {
      let activity = AppActivity(center: center)
      center.post(UIApplication.DidBecomeActiveMessage())
      center.post(UIApplication.WillResignActiveMessage())
      #expect(!activity.isActive)
      center.post(UIApplication.DidEnterBackgroundMessage())
      #expect(!activity.isActive)
      center.post(UIApplication.DidBecomeActiveMessage())
      #expect(activity.isActive)
    }

    @Test func followsUIKitsNotifications() {
      let activity = AppActivity(center: center)
      center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
      #expect(activity.isActive)
      center.post(name: UIApplication.willResignActiveNotification, object: nil)
      #expect(!activity.isActive)
    }

    @Test func stopsObservingWhenReleased() {
      var activity: AppActivity? = AppActivity(center: center)
      weak let released = activity
      activity = nil
      #expect(released == nil)
      center.post(UIApplication.DidBecomeActiveMessage())
    }
  }
#endif
