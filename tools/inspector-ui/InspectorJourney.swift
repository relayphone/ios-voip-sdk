import XCTest

@MainActor
final class InspectorJourney: XCTestCase {
  private var filterConfirmation: NSPredicate {
    NSPredicate(format: "value == 1 AND enabled == true")
  }

  func testFilterConfirmationRequiresCheckedAndEnabled() {
    XCTAssertTrue(filterConfirmation.evaluate(with: CheckboxSnapshot(value: 1, enabled: true)))
    XCTAssertFalse(filterConfirmation.evaluate(with: CheckboxSnapshot(value: 0, enabled: true)))
    XCTAssertFalse(filterConfirmation.evaluate(with: CheckboxSnapshot(value: 2, enabled: true)))
    XCTAssertFalse(filterConfirmation.evaluate(with: CheckboxSnapshot(value: 1, enabled: false)))
  }

  func testIncomingCallAndFilter() throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "dev.callkitsim.inspector")
    // The app is already running with the bridge credentials supplied by cksim inspect.
    app.activate()
    let readyPath = try XCTUnwrap(
      ProcessInfo.processInfo.environment["CKSIM_INSPECTOR_READY_FILE"])
    try Data().write(to: URL(fileURLWithPath: readyPath), options: .atomic)
    let banner = app.buttons["expand-call"]
    XCTAssertTrue(banner.waitForExistence(timeout: 30))
    banner.click()
    let sheet = app.sheets.firstMatch
    let answer = sheet.buttons["answer"]
    XCTAssertTrue(answer.waitForExistence(timeout: 10))
    clickWhenEnabled(answer)
    let status = sheet.staticTexts["call-status"]
    XCTAssertTrue(status.waitForExistence(timeout: 10))
    XCTAssertTrue(wait(status, value: "Connected"))
    attach(app, name: "Connected call")
    clickWhenEnabled(sheet.buttons["end"])
    XCTAssertTrue(wait(status, value: "Ended"))
    attach(app, name: "Ended call")
    sheet.buttons["dismiss-call"].click()
    let filter = app.checkBoxes["incoming-filter-do-not-disturb"]
    for _ in 0..<12 {
      if filter.exists && filter.isHittable { break }
      app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -400)
    }
    XCTAssertTrue(filter.isHittable)
    clickWhenEnabled(filter)
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: filterConfirmation, object: filter)], timeout: 15
      ),
      .completed)
    attach(app, name: "Filter confirmed")
  }

  private func wait(_ element: XCUIElement, value: String) -> Bool {
    XCTWaiter.wait(
      for: [
        XCTNSPredicateExpectation(
          predicate: NSPredicate(format: "value == %@", value), object: element)
      ],
      timeout: 20) == .completed
  }

  private func attach(_ app: XCUIApplication, name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "\(name) hierarchy"
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
  }

  private func clickWhenEnabled(_ element: XCUIElement) {
    let enabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
    element.click()
  }
}

private final class CheckboxSnapshot: NSObject {
  @objc let value: Int
  @objc let enabled: Bool

  init(value: Int, enabled: Bool) {
    self.value = value
    self.enabled = enabled
  }
}
