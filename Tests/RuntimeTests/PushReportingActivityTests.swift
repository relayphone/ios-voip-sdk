#if os(iOS) && targetEnvironment(simulator)
  import Foundation
  import Testing
  import UIKit

  @testable import CKSimRuntime

  @MainActor
  struct PushReportingActivityTests {
    @Test func aBackgroundLaunchUsesTheJoinedCallBudgetAfterLaunchFinishes() throws {
      let center = NotificationCenter()
      let activity = RuntimeApplicationActivity(center: center, applicationState: { .background })
      defer { activity.stop() }
      #expect(activity.state == .launching)
      center.post(UIApplication.DidFinishLaunchingMessage())
      #expect(activity.state == .background)
      let profile = try JSONDecoder().decode(
        BehaviorProfile.self, from: Data(BehaviorProfile.embeddedJSON.utf8))
      #expect(
        profile.pushReporting.rule(application: activity.state, joinedCall: true).seconds == 30)
    }

    @Test func firstObservationOnMainSamplesAnAlreadyLaunchedApp() async {
      let observed = AsyncStream<Void>.makeStream()
      let activity = RuntimeApplicationActivity(
        center: NotificationCenter(),
        applicationState: {
          observed.continuation.yield(())
          return .background
        })
      defer { activity.stop() }
      var iterator = observed.stream.makeAsyncIterator()
      _ = await iterator.next()
      #expect(activity.state == .background)
    }

    @Test func stoppingBeforeTheFirstObservationKeepsItFromChangingState() async {
      let observed = AsyncStream<Void>.makeStream()
      let activity = RuntimeApplicationActivity(
        center: NotificationCenter(),
        applicationState: {
          observed.continuation.yield(())
          return .background
        })
      activity.stop()
      var iterator = observed.stream.makeAsyncIterator()
      _ = await iterator.next()
      #expect(activity.state == .launching)
    }

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
