import XCTest

@MainActor
final class InspectorJourney: XCTestCase {
  func testIncomingCallAndFilter() {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "dev.callkitsim.inspector")
    // The app is already running with the bridge credentials supplied by cksim inspect.
    app.activate()
    let banner = app.buttons["expand-call"]
    XCTAssertTrue(banner.waitForExistence(timeout: 30))
    banner.tap()
    attach(app, name: "Incoming call")
    let answer = app.buttons["answer"]
    XCTAssertTrue(answer.waitForExistence(timeout: 10))
    tapWhenEnabled(answer)
    let status = app.staticTexts["call-status"]
    XCTAssertTrue(status.waitForExistence(timeout: 10))
    XCTAssertTrue(
      NSPredicate(format: "label == %@", "Connected").evaluate(with: status)
        || wait(status, label: "Connected"))
    attach(app, name: "Connected call")
    tapWhenEnabled(app.buttons["end"])
    XCTAssertTrue(wait(status, label: "Ended"))
    attach(app, name: "Ended call")
    app.buttons["dismiss-call"].tap()
    let filter = app.switches["incoming-filter-do-not-disturb"]
    for _ in 0..<12 {
      if filter.exists && filter.isHittable { break }
      app.swipeUp()
    }
    XCTAssertTrue(filter.isHittable)
    tapWhenEnabled(filter)
    let confirmed = NSPredicate(format: "value == %@ AND enabled == true", "1")
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: confirmed, object: filter)], timeout: 15),
      .completed)
    attach(app, name: "Filter confirmed")
  }

  private func wait(_ element: XCUIElement, label: String) -> Bool {
    XCTWaiter.wait(
      for: [
        XCTNSPredicateExpectation(
          predicate: NSPredicate(format: "label == %@", label), object: element)
      ],
      timeout: 20) == .completed
  }

  private func attach(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func tapWhenEnabled(_ element: XCUIElement) {
    let enabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
    element.tap()
  }
}
