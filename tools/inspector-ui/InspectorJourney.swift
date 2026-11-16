import XCTest

@MainActor
final class InspectorJourney: XCTestCase {
  private var filterConfirmation: NSPredicate {
    NSPredicate(format: "(value == 1 OR value == '1') AND enabled == true")
  }

  func testFilterConfirmationRequiresCheckedAndEnabled() {
    for value in [NSNumber(value: 1), true, "1"] as [Any] {
      XCTAssertTrue(
        filterConfirmation.evaluate(with: CheckboxSnapshot(value: value, enabled: true)))
      XCTAssertFalse(
        filterConfirmation.evaluate(with: CheckboxSnapshot(value: value, enabled: false)))
    }
    for value in [NSNumber(value: 0), false, "0", NSNumber(value: 2), "2"] as [Any] {
      XCTAssertFalse(
        filterConfirmation.evaluate(with: CheckboxSnapshot(value: value, enabled: true)))
      XCTAssertFalse(
        filterConfirmation.evaluate(with: CheckboxSnapshot(value: value, enabled: false)))
    }
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
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
    let filter = app.checkBoxes["incoming-filter-do-not-disturb"]
    for _ in 0..<12 {
      if filter.exists && filter.isHittable { break }
      app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -400)
    }
    XCTAssertTrue(filter.isHittable)
    clickWhenEnabled(filter)
    attachCheckbox(filter, name: "Filter after click")
    let confirmation = XCTWaiter.wait(
      for: [XCTNSPredicateExpectation(predicate: filterConfirmation, object: filter)], timeout: 15)
    if confirmation != .completed {
      attachCheckbox(filter, name: "Filter confirmation timeout")
      attach(app, name: "Filter confirmation failed")
    }
    XCTAssertEqual(confirmation, .completed)
    attach(app, name: "Filter confirmed")
  }

  private func attachCheckbox(_ filter: XCUIElement, name: String) {
    let value = filter.value
    let details = """
      type(of: filter.value): \(String(describing: type(of: filter.value)))
      unwrapped type: \(value.map { String(describing: type(of: $0)) } ?? "nil")
      value: \(String(describing: value))
      isEnabled: \(filter.isEnabled)
      """
    print("\(name):\n\(details)")
    let observation = XCTAttachment(string: details)
    observation.name = name
    observation.lifetime = .keepAlways
    add(observation)
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
  @objc let value: Any
  @objc let enabled: Bool

  init(value: Any, enabled: Bool) {
    self.value = value
    self.enabled = enabled
  }
}
