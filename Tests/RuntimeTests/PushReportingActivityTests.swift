#if os(iOS) && targetEnvironment(simulator)
  import Foundation
  import Testing
  import UIKit

  @testable import CKSimRuntime

  @MainActor
  struct PushReportingActivityTests {
    @Test func activityChangesSelectTheReportingBudgetSynchronously() {
      let center = NotificationCenter()
      let activity = RuntimeApplicationActivity(center: center)
      #expect(activity.state == .launching)
      center.post(UIApplication.DidBecomeActiveMessage())
      #expect(activity.state == .foreground)
      center.post(UIApplication.DidEnterBackgroundMessage())
      #expect(activity.state == .background)
      center.post(UIApplication.WillEnterForegroundMessage())
      #expect(activity.state == .foreground)
      activity.stop()
      center.post(UIApplication.DidEnterBackgroundMessage())
      #expect(activity.state == .foreground)
    }
  }
#endif
