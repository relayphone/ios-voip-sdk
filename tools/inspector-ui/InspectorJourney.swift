import XCTest

@MainActor
final class InspectorJourney: XCTestCase {
  private let clock = ContinuousClock()
  private let started = ContinuousClock.now
  private var stepsURL: URL?

  private enum Step: String, Encodable {
    case activationStarted, activationCompleted, pushRequested, reportWaitStarted, callReported
    case rowWaitStarted, rowVisible, expandClickStarted, expandClickCompleted
    case answerVisible, connected, ended, filterConfirmed
  }
  private struct Timing: Encodable {
    let step: Step
    let wallTime: Date
    let elapsed: String
    let reportWallTimeMS: UInt64?
  }
  private enum Failure: Error { case reportMissing }
  private func mark(_ step: Step, reportWallTimeMS: UInt64? = nil) throws {
    let timing = Timing(
      step: step, wallTime: Date(), elapsed: String(describing: started.duration(to: clock.now)),
      reportWallTimeMS: reportWallTimeMS)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var data = try encoder.encode(timing)
    data.append(10)
    print("Inspector step: \(String(decoding: data, as: UTF8.self))", terminator: "")
    if let stepsURL {
      let file = try FileHandle(forWritingTo: stepsURL)
      defer { try? file.close() }
      try file.seekToEnd()
      try file.write(contentsOf: data)
    }
  }
  private struct Report: Decodable {
    let event: String
    let code: Int?
    let wallTimeMS: UInt64
  }
  private func waitForReport(at url: URL) async throws -> UInt64 {
    let deadline = clock.now.advanced(by: .seconds(30))
    repeat {
      let journal = try Data(contentsOf: url)
      for line in journal.split(separator: 10) {
        if let report = try? JSONDecoder().decode(Report.self, from: Data(line)),
          report.event == "report.incoming", report.code == 0
        {
          return report.wallTimeMS
        }
      }
      try await clock.sleep(for: .milliseconds(100))
    } while clock.now < deadline
    throw Failure.reportMissing
  }

  func testReportTimestampComesFromSuccessfulRuntimeReport() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let journal = """
      {"event":"push.received","wallTimeMS":100}
      {"event":"report.incoming","code":4,"wallTimeMS":101}
      {"event":"report.incoming","code":0,"wallTimeMS":102}
      {"event":
      """
    try Data(journal.utf8).write(to: file)
    let reportedAt = try await waitForReport(at: file)
    XCTAssertEqual(reportedAt, 102)
  }
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

  func testIncomingCallAndFilter() async throws {
    continueAfterFailure = false
    let readyPath = try XCTUnwrap(
      ProcessInfo.processInfo.environment["CKSIM_INSPECTOR_READY_FILE"])
    let journalPath = try XCTUnwrap(
      ProcessInfo.processInfo.environment["CKSIM_INSPECTOR_JOURNAL_FILE"])
    stepsURL = URL(fileURLWithPath: readyPath + ".steps.jsonl")
    try Data().write(to: XCTUnwrap(stepsURL), options: .atomic)
    let app = XCUIApplication(bundleIdentifier: "dev.callkitsim.inspector")
    // The app is already running with the bridge credentials supplied by cksim inspect.
    try mark(.activationStarted)
    app.activate()
    try mark(.activationCompleted)
    try mark(.pushRequested)
    try Data().write(to: URL(fileURLWithPath: readyPath), options: .atomic)
    try mark(.reportWaitStarted)
    let reportedAt = try await waitForReport(at: URL(fileURLWithPath: journalPath))
    try mark(.callReported, reportWallTimeMS: reportedAt)
    let banner = app.buttons["expand-call"]
    try mark(.rowWaitStarted)
    XCTAssertTrue(banner.waitForExistence(timeout: 30))
    try mark(.rowVisible)
    try mark(.expandClickStarted)
    banner.click()
    try mark(.expandClickCompleted)
    let sheet = app.sheets.firstMatch
    let answer = sheet.buttons["answer"]
    XCTAssertTrue(answer.waitForExistence(timeout: 10))
    try mark(.answerVisible)
    clickWhenEnabled(answer)
    let status = sheet.staticTexts["call-status"]
    XCTAssertTrue(status.waitForExistence(timeout: 10))
    XCTAssertTrue(wait(status, value: "Connected"))
    try mark(.connected)
    attach(app, name: "Connected call")
    clickWhenEnabled(sheet.buttons["end"])
    XCTAssertTrue(wait(status, value: "Ended"))
    try mark(.ended)
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
    let confirmation = await XCTWaiter.fulfillment(
      of: [XCTNSPredicateExpectation(predicate: filterConfirmation, object: filter)], timeout: 15)
    if confirmation != .completed {
      attachCheckbox(filter, name: "Filter confirmation timeout")
      attach(app, name: "Filter confirmation failed")
    }
    XCTAssertEqual(confirmation, .completed)
    try mark(.filterConfirmed)
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
