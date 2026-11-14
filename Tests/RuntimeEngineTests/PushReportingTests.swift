import Foundation
import Testing

@testable import CKSimRuntime

struct PushReportingTests {
  private func check(_ result: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(result, sourceLocation: sourceLocation)
  }

  @Test func theProfileSeparatesMeasuredContextsFromFallbackPolicy() throws {
    let profile = try behaviorProfile().pushReporting
    for application in [PushReportingProfile.ApplicationState.foreground, .launching] {
      let rule = profile.rule(application: application, joinedCall: false)
      #expect(rule.seconds == 4.4 && rule.verification == .verified)
    }
    let background = profile.rule(application: .background, joinedCall: true)
    #expect(background.seconds == 30 && background.verification == .verified)
    for (application, joined) in [
      (PushReportingProfile.ApplicationState.background, false), (.foreground, true),
      (.unknown, false),
    ] {
      let rule = profile.rule(application: application, joinedCall: joined)
      #expect(rule.seconds == 4.4 && rule.verification == .unverified)
    }
  }

  @Test(arguments: [4.4, 30.0])
  func anUnreportedPushExpiresAtItsBudgetEvenAfterCompletion(seconds: Double) throws {
    var obligations = PushReportingObligations()
    check(obligations.receive("push", required: true, now: .seconds(12), budget: .seconds(seconds)))
    let token = try #require(obligations.deadlineToken("push"))
    #expect(!obligations.completed("push").reportEntered)
    #expect(!obligations.returned("push").reportEntered)
    let due = Duration.seconds(12) + .seconds(seconds)
    check(!obligations.expire("push", token: token, now: due - .milliseconds(1)))
    check(obligations.expire("push", token: token, now: due))
    check(!obligations.expire("push", token: token, now: due + .seconds(1)))
  }

  @Test func theMeasuredLateReportSurvivesAfterTheDelegateReturns() throws {
    struct Row: Decodable {
      let event: String
      let timeMS: Int
      enum CodingKeys: String, CodingKey {
        case event
        case timeMS = "t_ms"
      }
    }
    let file = repository.appending(
      path:
        "Tests/Fixtures/LiveCommunicationKit/push/2026-10-23-iphone13-ios27-late-report-3s.jsonl")
    let rows = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
      try JSONDecoder().decode(Row.self, from: Data($0.utf8))
    }
    let received = try #require(rows.first { $0.event == "lckpush.received" })
    let report = try #require(rows.first { $0.event == "lckpush.reportStart" })
    var obligations = PushReportingObligations()
    check(obligations.receive("late", required: true, now: .zero, budget: .seconds(4.4)))
    let token = try #require(obligations.deadlineToken("late"))
    #expect(obligations.returned("late").violation != nil)
    #expect(obligations.awaitingReport() == "late")
    check(
      obligations.entered(
        "late", call: UUID(), alreadyKnown: false,
        now: .milliseconds(report.timeMS - received.timeMS)))
    #expect(obligations.completed("late").reportEntered)
    check(!obligations.expire("late", token: token, now: .seconds(5)))
  }

  @Test func aReportAtFiveSecondsIsTooLateEvenIfTheTimerHasntRun() throws {
    var obligations = PushReportingObligations()
    check(obligations.receive("late", required: true, now: .zero, budget: .seconds(4.4)))
    let token = try #require(obligations.deadlineToken("late"))
    check(!obligations.entered("late", call: UUID(), alreadyKnown: false, now: .seconds(5)))
    check(obligations.expire("late", token: token, now: .seconds(5)))
  }

  @Test func anExistingUUIDDoesNotSatisfyAnotherPushEvenAfterTheCallEnds() throws {
    var obligations = PushReportingObligations()
    let call = UUID()
    check(!obligations.entered("", call: call, alreadyKnown: false, now: .zero))
    check(obligations.receive("repeat", required: true, now: .zero, budget: .seconds(30)))
    let token = try #require(obligations.deadlineToken("repeat"))
    check(!obligations.entered("repeat", call: call, alreadyKnown: true, now: .seconds(1)))
    check(!obligations.entered("repeat", call: call, alreadyKnown: false, now: .seconds(2)))
    check(obligations.expire("repeat", token: token, now: .seconds(30)))
  }

  @Test func anOutgoingCallsUUIDDoesNotSatisfyTheObligation() throws {
    var obligations = PushReportingObligations()
    check(obligations.receive("push", required: true, now: .zero, budget: .seconds(4.4)))
    check(!obligations.entered("push", call: UUID(), alreadyKnown: true, now: .seconds(1)))
    let token = try #require(obligations.deadlineToken("push"))
    check(obligations.expire("push", token: token, now: .seconds(4.4)))
  }

  @Test func mustReportFalseNeverExpires() throws {
    var obligations = PushReportingObligations()
    check(obligations.receive("optional", required: false, now: .zero, budget: .seconds(4.4)))
    let token = try #require(obligations.deadlineToken("optional"))
    check(!obligations.expire("optional", token: token, now: .seconds(600)))
    #expect(obligations.completed("optional").violation == nil)
    #expect(obligations.returned("optional").violation == nil)
  }

  @Test func oneNewUUIDCanSatisfyOnlyOneDelivery() throws {
    var obligations = PushReportingObligations()
    for id in ["one", "two"] {
      check(obligations.receive(id, required: true, now: .zero, budget: .seconds(4.4)))
    }
    let call = UUID()
    #expect(obligations.awaitingReport() == "one")
    check(obligations.entered("one", call: call, alreadyKnown: false, now: .seconds(1)))
    #expect(obligations.awaitingReport() == "two")
    check(!obligations.entered("two", call: call, alreadyKnown: true, now: .seconds(2)))
    let token = try #require(obligations.deadlineToken("two"))
    check(obligations.expire("two", token: token, now: .seconds(4.4)))
  }
}
