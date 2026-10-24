import XCTest

@MainActor
final class InspectorUITests: XCTestCase {
  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  func testAnswerFromInspector() {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "dev.callkitsim.inspector")
    app.activate()
    // The host injects after XCTest starts; allow its 120-second control budget.
    XCTAssertTrue(app.buttons["expand-call"].waitForExistence(timeout: 130))
    capture("incoming-banner")
    app.buttons["expand-call"].tap()
    XCTAssertTrue(app.staticTexts["call-status"].waitForExistence(timeout: 5))
    let answer = app.scrollViews.buttons["answer"]
    XCTAssertTrue(answer.waitForExistence(timeout: 5))
    capture("incoming-full-screen")
    answer.tap()
    let connected = app.staticTexts["call-status"]
    let predicate = NSPredicate(format: "label == %@", "Connected")
    expectation(for: predicate, evaluatedWith: connected)
    waitForExpectations(timeout: 15)
    XCTAssertTrue(app.scrollViews.staticTexts["Audio active"].waitForExistence(timeout: 10))
    capture("answered-from-inspector")
    app.buttons["Show timeline"].tap()
    XCTAssertEqual(app.staticTexts["audio-state"].label, "Audio active")
    app.swipeUp()
    let latency = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Answer fulfilled", "profile budget")).firstMatch
    XCTAssertTrue(latency.waitForExistence(timeout: 5))
    capture("live-timeline")
  }
}
