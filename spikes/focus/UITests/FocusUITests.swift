import XCTest

// English UI selectors are deliberately fail-closed. A generic build does not qualify them on iOS.
final class FocusUITests: XCTestCase {
  let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
  let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
  let contacts = XCUIApplication(bundleIdentifier: "com.apple.MobileAddressBook")
  let probe = XCUIApplication(bundleIdentifier: "dev.callkitsim.focus")
  let callUI = XCUIApplication(bundleIdentifier: "com.apple.InCallService")
  struct Journal: Codable {
    var focusName = "Focus Probe 124"
    var contactName = "Focus Probe 124 " + UUID().uuidString.prefix(8)
    var captured = false
    var initialFocus: String?
    var ownsFocus = false
    var ownsContact = false
  }
  var journal = Journal()
  var events: [[String: Any]] = []
  var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
  func save() throws {
    try JSONEncoder().encode(journal).write(to: documents.appendingPathComponent("focus-ui-state.json"), options: .atomic)
  }
  func front(_ app: XCUIApplication) throws {
    guard app.state == .runningForeground else { throw failure("Expected app is not foreground") }
  }
  func failure(_ text: String) -> NSError { NSError(domain: "FocusUI", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
  func element(_ app: XCUIApplication, _ labels: [String], timeout: Double = 4) throws -> XCUIElement {
    let end = Date().addingTimeInterval(timeout)
    repeat {
      try front(app)
      for label in labels {
        let query = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label))
        if let item = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return item }
      }
      Thread.sleep(forTimeInterval: 0.2)
    } while Date() < end
    throw failure("Missing control: \(labels.joined(separator: "/"))")
  }
  @nonobjc func tap(_ app: XCUIApplication, _ element: XCUIElement) throws {
    try front(app)
    guard element.exists && element.isHittable else { throw failure("Control no longer hittable") }
    element.tap()
  }
  @nonobjc func tap(_ app: XCUIApplication, _ labels: [String]) throws { try tap(app, element(app, labels)) }
  func type(_ app: XCUIApplication, _ field: XCUIElement, _ text: String) throws {
    try tap(app, field); try front(app)
    let old = (field.value as? String).flatMap { $0 == field.placeholderValue ? nil : $0 } ?? ""
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + text)
  }
  func scrollTo(_ app: XCUIApplication, _ labels: [String]) throws -> XCUIElement {
    for _ in 0..<7 {
      if let item = try? element(app, labels, timeout: 0.3) { return item }
      try front(app); app.swipeUp()
    }
    throw failure("Could not scroll to \(labels.joined(separator: "/"))")
  }
  func home() { XCUIDevice.shared.press(.home) }

  func focusMenu() throws {
    home(); XCTAssertTrue(board.wait(for: .runningForeground, timeout: 5)); try front(board)
    let start = board.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.01))
    start.press(forDuration: 0.1, thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.65)))
    let tile = board.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR identifier == %@", "Focus", "Focus")).firstMatch
    // An active Focus may replace the tile's accessible name.
    if tile.waitForExistence(timeout: 3) { try tap(board, tile) }
    else if let name = journal.initialFocus { try tap(board, [name]) }
    else { throw failure("Control Center Focus tile unavailable") }
    _ = try element(board, ["Do Not Disturb"])
  }
  func selectedFocus() throws -> String? {
    try front(board)
    let selected = board.buttons.allElementsBoundByIndex.filter {
      $0.isHittable && ($0.isSelected || ($0.value as? String) == "On")
    }
    guard selected.count <= 1 else { throw failure("Ambiguous active Focus") }
    return selected.first?.label.components(separatedBy: ",").first
  }
  func setFocus(_ name: String, enabled: Bool) throws {
    try focusMenu()
    let current = try selectedFocus()
    if (current == name) != enabled {
      let button = board.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", name, name + ",")).firstMatch
      try tap(board, button)
    }
    home(); try focusMenu()
    guard ((try selectedFocus()) == name) == enabled else { throw failure("Focus toggle did not converge") }
    home()
  }
  func openFocusList() throws {
    settings.terminate(); settings.launch()
    try tap(settings, scrollTo(settings, ["Focus"]))
  }
  func openProfile() throws {
    try openFocusList(); try tap(settings, [journal.focusName])
  }
  func setup() throws {
    if !journal.captured {
      try focusMenu(); journal.initialFocus = try selectedFocus(); journal.captured = true; try save(); home()
    }
    try openFocusList()
    if (try? element(settings, [journal.focusName], timeout: 1)) != nil {
      guard journal.ownsFocus else { throw failure("Chosen Focus already exists without an ownership journal") }
    } else {
      try tap(settings, ["Add", "Add Focus"]); try tap(settings, ["Custom"])
      let name = settings.textFields.firstMatch
      XCTAssertTrue(name.waitForExistence(timeout: 4)); try type(settings, name, journal.focusName)
      // Persist ownership intent before the creation tap, for interrupted-run restoration.
      journal.ownsFocus = true; try save()
      try tap(settings, ["Next"]); try tap(settings, ["Customize Focus", "Customise Focus"])
    }
    if !journal.ownsContact { try createContact() }
  }
  func openContact() throws -> Bool {
    contacts.terminate(); contacts.launch()
    for _ in 0..<4 where !contacts.searchFields.firstMatch.exists {
      guard let back = try? element(contacts, ["Contacts", "Back", "Lists"], timeout: 1) else { break }
      try tap(contacts, back)
    }
    let search = contacts.searchFields.firstMatch
    guard search.waitForExistence(timeout: 4) else { throw failure("Contacts search unavailable") }
    try type(contacts, search, journal.contactName)
    guard let match = try? element(contacts, [journal.contactName], timeout: 2) else { return false }
    try tap(contacts, match); return true
  }
  func createContact() throws {
    guard try !openContact() else { throw failure("Test contact name collision") }
    contacts.terminate(); contacts.launch()
    try tap(contacts, ["Add", "Add Contact", "New Contact"])
    try type(contacts, element(contacts, ["First name", "First Name"]), journal.contactName)
    try tap(contacts, scrollTo(contacts, ["add phone", "Add phone"]))
    try front(contacts); contacts.typeText(ProcessInfo.processInfo.environment["FOCUS_CALLER"] ?? "+15555550199")
    journal.ownsContact = true; try save()
    try tap(contacts, ["Done"])
    guard try openContact() else { throw failure("Created contact could not be verified") }
  }
  func setMember(_ kind: String, include: Bool) throws {
    try openProfile(); try tap(settings, [kind])
    // This is a dedicated owned profile; never mutate another Focus's list mode.
    try tap(settings, ["Allow Notifications From"])
    let name = kind == "Apps" ? "Focus Probe" : journal.contactName
    let present = (try? element(settings, [name], timeout: 1)) != nil
    if present == include { return }
    if include {
      try tap(settings, kind == "Apps" ? ["Add Apps", "Add"] : ["Add People", "Add"])
      let search = settings.searchFields.firstMatch
      if search.waitForExistence(timeout: 2) { try type(settings, search, name) }
      try tap(settings, element(settings, [name], timeout: 5)); try tap(settings, ["Done"])
    } else {
      // Exact accessibility names only; no unverified coordinate deletion.
      try tap(settings, ["Remove \(name)", "Delete \(name)"])
    }
    guard ((try? element(settings, [name], timeout: 2)) != nil) == include else { throw failure("\(kind) membership did not converge") }
  }
  func setCalls(_ value: String) throws {
    try openProfile(); try tap(settings, ["People"])
    try tap(settings, scrollTo(settings, ["Allow Calls From", "Calls From"]))
    try tap(settings, [value])
    try openProfile(); try tap(settings, ["People"])
    // Reopen the profile: seeing a menu option is not evidence of its selected value.
    _ = try element(settings, [value])
  }
  func setPolicy() throws {
    try openProfile(); try tap(settings, scrollTo(settings, ["Add Filter"]))
    try tap(settings, ["Focus Probe", "AI call policy"])
    try tap(settings, ["Policy", "Decline"]); try tap(settings, ["AI screens calls"])
    try tap(settings, ["Add", "Done"])
  }
  func restore() throws {
    guard journal.captured else { return }
    if journal.ownsFocus {
      try openFocusList()
      if (try? element(settings, [journal.focusName], timeout: 1)) != nil {
        try setFocus(journal.focusName, enabled: false)
        try openProfile(); try tap(settings, scrollTo(settings, ["Delete Focus"]))
        try tap(settings, ["Delete Focus"])
        try openFocusList()
        guard (try? element(settings, [journal.focusName], timeout: 1)) == nil else { throw failure("Focus still present after deletion") }
      }
      journal.ownsFocus = false; try save()
    }
    if journal.ownsContact {
      if try openContact() {
        try tap(contacts, ["Edit"]); try tap(contacts, scrollTo(contacts, ["Delete Contact"]))
        try tap(contacts, ["Delete Contact", "Delete"])
        guard try !openContact() else { throw failure("Test contact still present") }
      }
      journal.ownsContact = false; try save()
    }
    if let initial = journal.initialFocus { try setFocus(initial, enabled: true) }
    journal.captured = false; try save(); home()
  }
  func authorize(_ focus: Bool, allow: Bool) throws {
    probe.activate()
    try tap(probe, [focus ? "focus.authorize" : "focus.notifications"])
    // A previously settled authorization has no dialog. Do not tap unrelated alerts.
    let alert = probe.alerts.firstMatch
    if alert.waitForExistence(timeout: 3) { try tap(probe, alert.buttons[allow ? "Allow" : "Don’t Allow"]) }
  }
  func observe(_ duration: Double) throws {
    home()
    let end = Date().addingTimeInterval(min(max(duration, 1), 90))
    var banner = false, fullScreen = false
    repeat {
      if board.state == .runningForeground {
        banner = banner || board.buttons.matching(NSPredicate(format: "label IN %@", ["Accept", "Answer call", "Decline"])).firstMatch.exists
      }
      fullScreen = fullScreen || (callUI.state == .runningForeground && callUI.otherElements["InCallRootView"].exists)
      Thread.sleep(forTimeInterval: 0.25)
    } while Date() < end
    events.append(["event": "call.observed", "banner": banner, "callScreen": fullScreen, "humanSound": "pending"])
  }
  func testActions() throws {
    continueAfterFailure = false
    let env = ProcessInfo.processInfo.environment
    let state = documents.appendingPathComponent("focus-ui-state.json")
    if let recovery = env["FOCUS_RESTORE_STATE"], let data = Data(base64Encoded: recovery) {
      journal = try JSONDecoder().decode(Journal.self, from: data)
    } else if let data = try? Data(contentsOf: state) { journal = try JSONDecoder().decode(Journal.self, from: data) }
    if let name = env["FOCUS_NAME"] {
      guard name.hasPrefix("Focus Probe"), !journal.captured || name == journal.focusName else { throw failure("Use a dedicated Focus Probe profile and matching recovery journal") }
      journal.focusName = name
    }
    let actions = try JSONDecoder().decode([String].self, from: Data((env["FOCUS_ACTIONS"] ?? "[]").utf8))
    do {
      for action in actions {
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        let value = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "setup": try setup()
        case "focus": try setFocus(journal.focusName, enabled: value == "on")
        case "app": try setMember("Apps", include: value == "include")
        case "person": try setMember("People", include: value == "include")
        case "calls": try setCalls(value)
        case "policy": try setPolicy()
        case "restore-all": try restore()
        case "notifications": try authorize(false, allow: value == "allow")
        case "focus-authorization": try authorize(true, allow: value == "allow")
        case "sample": probe.activate(); try tap(probe, ["focus.sample"])
        case "launch": probe.terminate(); probe.launch()
        case "home": home()
        case "observe": try observe(Double(value) ?? 35)
        default: throw failure("Unknown action \(action)")
        }
        events.append(["action": action, "status": "ok"])
      }
      try writeResult("ok")
    } catch {
      try? writeResult("failed"); throw error
    }
  }
  func writeResult(_ status: String) throws {
    try JSONSerialization.data(withJSONObject: ["status": status, "events": events], options: [.sortedKeys])
      .write(to: documents.appendingPathComponent("focus-ui-result.json"), options: .atomic)
  }
}
