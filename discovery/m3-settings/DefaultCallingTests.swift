import Darwin
import XCTest

/// Public Settings controls observed on iOS 26.5 and 27.0. Other OS versions must pass
/// their own measured run; a missing control fails with the actual UI attached.
final class DefaultCallingTests: XCTestCase {
  @MainActor private func capture(_ app: XCUIApplication, _ stage: String) {
    let screen = XCTAttachment(screenshot: app.screenshot())
    screen.name = stage + "-screen"; screen.lifetime = .keepAlways; add(screen)
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = stage + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
  }

  @MainActor private func observedSettingsList(_ settings: XCUIApplication) -> XCUIElement? {
    let named = settings.collectionViews["com.apple.settings.sidebar.collectionView"]
    if named.waitForExistence(timeout: 10) { return named }
    // iOS 26.5's captured Settings tree has one unnamed collection view.
    let candidates = settings.collectionViews
    guard candidates.count == 1 else { return nil }
    return candidates.element(boundBy: 0)
  }

  @MainActor func testSelectCallingApp() throws {
    continueAfterFailure = false
    let environment = ProcessInfo.processInfo.environment
    let runID = try XCTUnwrap(environment["SDK_M3_SETTINGS_RUN_ID"])
    let simulator = try XCTUnwrap(environment["SDK_M3_SETTINGS_SIMULATOR_ID"])
    let pid = try XCTUnwrap(environment["SDK_M3_SETTINGS_APP_PID"].flatMap(Int.init))
    XCTAssertFalse(runID.isEmpty); XCTAssertGreaterThan(pid, 0)
    XCTAssertEqual(environment["SIMULATOR_UDID"], simulator)
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    settings.launch()
    guard settings.wait(for: .runningForeground, timeout: 20) else {
      capture(settings, "not-foreground"); XCTFail("Settings did not launch"); return
    }
    capture(settings, "root")
    guard let list = observedSettingsList(settings) else {
      capture(settings, "list-missing"); XCTFail("Observed Settings list missing"); return
    }
    let apps = settings.buttons["com.apple.settings.apps"]
    for _ in 0..<4 where !apps.isHittable { list.swipeUp() }
    guard apps.isHittable else {
      capture(settings, "apps-missing"); XCTFail("Observed Apps control missing"); return
    }
    apps.tap()
    let defaults = settings.staticTexts["Default Apps"].firstMatch
    guard defaults.waitForExistence(timeout: 30) else {
      capture(settings, "defaults-missing"); XCTFail("Observed Default Apps control missing"); return
    }
    defaults.tap()
    let calling = settings.staticTexts["Calling"].firstMatch
    guard calling.waitForExistence(timeout: 30) else {
      capture(settings, "calling-missing"); XCTFail("Observed Calling control missing"); return
    }
    calling.tap()
    let example = settings.buttons["VoIP SDK Example"]
    guard example.waitForExistence(timeout: 20), example.isHittable else {
      capture(settings, "candidate-missing"); XCTFail("Example is not an eligible calling app"); return
    }
    let before = example.isSelected
    capture(settings, "before-selection")
    example.tap()
    let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: example)
    let settled = XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
    capture(settings, "after-selection")
    XCTAssertTrue(settled)
    let row: [String: Any] = ["schemaVersion": 1, "runID": runID, "simulatorID": simulator,
      "appPID": pid, "method": "public-xctest-ui", "selected": example.isSelected,
      "beforeSelected": before, "tapped": true,
      "wallTimeMS": Int64(Date().timeIntervalSince1970 * 1000)]
    var line = Data("M3SETTINGS ".utf8)
    line.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); line.append(10)
    XCTAssertLessThanOrEqual(line.count, 4096)
    let written = line.withUnsafeBytes { write(STDERR_FILENO, $0.baseAddress, $0.count) }
    XCTAssertEqual(written, line.count, "Settings evidence write did not complete")
  }
}
