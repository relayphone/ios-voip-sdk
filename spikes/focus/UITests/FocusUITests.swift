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
    var caller = "+15555550199"
    var ownsContact = false
    var requiresProbeUninstall = false
    var autoLock: String?
    var autoAnswer: Bool?
    var autoAnswerDelay: String?
  }
  var journal = Journal()
  var verifiedFocusOff = false
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
  // Absence is only returned after a complete, stable scroll. Wrong-front errors propagate.
  func lookup(_ app: XCUIApplication, _ labels: [String], scan: Bool = true) throws -> XCUIElement? {
    func match() -> XCUIElement? {
      for label in labels {
        let items = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label))
        if let item = items.allElementsBoundByIndex.first(where: { $0.exists }) { return item }
      }
      return nil
    }
    try front(app)
    if let item = match() { return item }
    guard scan else { return nil }
    for _ in 0..<6 { try front(app); app.swipeDown() }
    var prior = ""
    for _ in 0..<16 {
      try front(app)
      if let item = match() { return item }
      let fingerprint = app.cells.allElementsBoundByIndex.filter(\.isHittable).map(\.label).joined(separator: "|")
      guard !fingerprint.isEmpty else { throw failure("Cannot establish list coverage") }
      if fingerprint == prior { return nil }
      prior = fingerprint; app.swipeUp()
    }
    throw failure("List coverage incomplete")
  }
  func home() { XCUIDevice.shared.press(.home) }

  func focusMenu() throws {
    home(); XCTAssertTrue(board.wait(for: .runningForeground, timeout: 5)); try front(board)
    let start = board.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.01))
    start.press(forDuration: 0.1, thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.65)))
    let tile = board.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR identifier == %@", "Focus", "Focus")).firstMatch
    // An active Focus may replace the tile's accessible name.
    verifiedFocusOff = false
    if tile.waitForExistence(timeout: 3) {
      verifiedFocusOff = ["Off", "0"].contains(tile.value as? String ?? "") || tile.label == "Focus, Off"
      try tap(board, tile)
    }
    else {
      let candidates = board.buttons.matching(NSPredicate(format: "label IN %@", ["Do Not Disturb", "Sleep", "Work", "Personal", "Driving", "Fitness"])).allElementsBoundByIndex.filter(\.isHittable)
      guard candidates.count == 1 else { throw failure("Control Center Focus tile unavailable/ambiguous") }
      try tap(board, candidates[0])
    }
    _ = try element(board, ["Do Not Disturb"])
  }
  func selectedFocus() throws -> String? {
    try front(board)
    let selected = board.buttons.allElementsBoundByIndex.filter {
      $0.isHittable && ($0.isSelected || ($0.value as? String) == "On")
    }
    guard selected.count <= 1 else { throw failure("Ambiguous active Focus") }
    guard !selected.isEmpty || verifiedFocusOff else { throw failure("Unknown Focus state; no verified Off marker") }
    return selected.first?.label.components(separatedBy: ",").first
  }
  func setFocus(_ name: String, enabled: Bool) throws {
    try focusMenu()
    let current = try selectedFocus()
    if (enabled && current != name) || (!enabled && current != nil) {
      let target = enabled ? name : current!
      let button = board.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", target, target + ",")).firstMatch
      try tap(board, button)
    }
    home(); try focusMenu()
    let actual = try selectedFocus()
    guard enabled ? actual == name : actual == nil else { throw failure("Focus toggle did not converge") }
    home()
  }
  func openFocusList() throws {
    settings.terminate(); settings.launch()
    try tap(settings, scrollTo(settings, ["Focus"]))
  }
  func openProfile() throws {
    try openFocusList(); try tap(settings, scrollTo(settings, [journal.focusName]))
  }
  func setup() throws {
    if !journal.captured {
      try focusMenu(); journal.initialFocus = try selectedFocus(); journal.captured = true; try save(); home()
    }
    try openFocusList()
    if try lookup(settings, [journal.focusName]) != nil {
      guard journal.ownsFocus else { throw failure("Chosen Focus already exists without an ownership journal") }
    } else {
      try tap(settings, ["Add", "Add Focus"]); try tap(settings, ["Custom"])
      let name = settings.textFields.firstMatch
      XCTAssertTrue(name.waitForExistence(timeout: 4)); try type(settings, name, journal.focusName)
      // Persist ownership intent before the creation tap, for interrupted-run restoration.
      journal.ownsFocus = true; try save()
      try tap(settings, ["Next"]); try tap(settings, ["Customize Focus", "Customise Focus"])
    }
    if try !openContact() { try createContact() }
    else if !journal.ownsContact { throw failure("Unowned test contact collision") }
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
    Thread.sleep(forTimeInterval: 1)
    guard let match = try lookup(contacts, [journal.contactName], scan: false) else { return false }
    try tap(contacts, match); return true
  }
  func createContact() throws {
    guard try !openContact() else { throw failure("Test contact name collision") }
    contacts.terminate(); contacts.launch()
    try tap(contacts, ["Add", "Add Contact", "New Contact"])
    try type(contacts, element(contacts, ["First name", "First Name"]), journal.contactName)
    try tap(contacts, scrollTo(contacts, ["add phone", "Add phone"]))
    try front(contacts); contacts.typeText(journal.caller)
    journal.ownsContact = true; try save()
    try tap(contacts, ["Done"])
    guard try openContact() else { throw failure("Created contact could not be verified") }
  }
  func setMember(_ kind: String, include: Bool) throws {
    try openProfile(); try tap(settings, [kind])
    // This is a dedicated owned profile; never mutate another Focus's list mode.
    try tap(settings, ["Allow Notifications From"])
    let name = kind == "Apps" ? "Focus Probe" : journal.contactName
    let present = try lookup(settings, [name]) != nil
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
    guard (try lookup(settings, [name]) != nil) == include else { throw failure("\(kind) membership did not converge") }
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
    try openProfile()
    if (try? element(settings, ["AI policy: screenWithAI"], timeout: 1)) != nil { return }
    try tap(settings, scrollTo(settings, ["Add Filter"]))
    try tap(settings, ["Focus Probe", "AI call policy"])
    try tap(settings, ["Policy", "Decline"]); try tap(settings, ["AI screens calls"])
    try tap(settings, ["Add", "Done"])
  }
  func setRepeatedCalls(_ enabled: Bool) throws {
    try openProfile(); try tap(settings, ["People"])
    _ = try scrollTo(settings, ["Allow Repeated Calls"])
    let item = settings.switches["Allow Repeated Calls"]
    guard ["0", "1"].contains(item.value as? String ?? "") else { throw failure("Repeated-calls state unavailable") }
    if ((item.value as? String) == "1") != enabled { try tap(settings, item) }
    guard ((item.value as? String) == "1") == enabled else { throw failure("Repeated-calls toggle failed") }
  }
  func restore() throws {
    guard journal.captured else { return }
    try restoreSystemSettings()
    if journal.ownsFocus {
      try openFocusList()
      if try lookup(settings, [journal.focusName]) != nil {
        try setFocus(journal.focusName, enabled: false)
        try openProfile(); try tap(settings, scrollTo(settings, ["Delete Focus"]))
        try tap(settings, ["Delete Focus"])
        try openFocusList()
        guard try lookup(settings, [journal.focusName]) == nil else { throw failure("Focus still present after deletion") }
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
  func authorizations() throws -> [String: Int] {
    probe.activate(); try tap(probe, ["focus.sample"])
    let end = Date().addingTimeInterval(5)
    repeat {
      let text = probe.staticTexts["focus.authorization.snapshot"].label
      if let value = try? JSONDecoder().decode([String: Int].self, from: Data(text.utf8)), value.count == 2 { return value }
      Thread.sleep(forTimeInterval: 0.2)
    } while Date() < end
    throw failure("Authorization readback unavailable")
  }
  func authorize(_ focus: Bool, allow: Bool) throws {
    try setup()
    let key = focus ? "focus" : "notifications"
    let wanted = focus ? (allow ? 3 : 2) : (allow ? 2 : 1)
    let before = try authorizations()[key]!
    if before == wanted { return }
    guard before == 0 else { throw failure("Settled authorization differs; use a clean test installation") }
    // Undetermined cannot be restored via Settings. Host restore uninstalls only this disposable probe.
    journal.requiresProbeUninstall = true; try save()
    try tap(probe, [focus ? "focus.authorize" : "focus.notifications"])
    let alert = probe.alerts.firstMatch
    guard alert.waitForExistence(timeout: 5) else { throw failure("Authorization prompt missing") }
    let labels = allow ? ["Allow"] : ["Don’t Allow", "Don't Allow"]
    try tap(probe, element(probe, labels))
    Thread.sleep(forTimeInterval: 0.5)
    guard try authorizations()[key] == wanted else { throw failure("Authorization did not match request") }
  }
  func autoLockPage() throws {
    settings.terminate(); settings.launch()
    try tap(settings, scrollTo(settings, ["Display & Brightness"]))
    try tap(settings, scrollTo(settings, ["Auto-Lock"]))
  }
  func selectedLock() throws -> String {
    try front(settings)
    let values = ["30 Seconds", "30 seconds", "1 Minute", "2 Minutes", "3 Minutes", "4 Minutes", "5 Minutes", "Never"]
    let selected = settings.descendants(matching: .any).allElementsBoundByIndex.filter {
      values.contains($0.label) && ($0.isSelected || ($0.value as? String) == "1" || ($0.value as? String) == "Selected")
    }
    let unique = Set(selected.map(\.label))
    guard unique.count == 1 else { throw failure("Auto-Lock selection cannot be verified") }
    return unique.first!
  }
  func autoAnswerPage() throws {
    settings.terminate(); settings.launch()
    try tap(settings, scrollTo(settings, ["Accessibility"]))
    try tap(settings, scrollTo(settings, ["Touch"]))
    try tap(settings, scrollTo(settings, ["Call Audio Routing"]))
    try tap(settings, scrollTo(settings, ["Auto-Answer Calls"]))
  }
  func answerSwitch() throws -> XCUIElement {
    try front(settings)
    let item = settings.switches["Auto-Answer Calls"]
    guard item.waitForExistence(timeout: 4), ["0", "1"].contains(item.value as? String ?? "") else { throw failure("Auto-Answer state unavailable") }
    return item
  }
  func delayText() throws -> String {
    try front(settings)
    let items = settings.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+([.][0-9]+)? [sS]econds?"))
    guard items.count == 1 else { throw failure("Auto-Answer delay unavailable") }
    return items.firstMatch.label
  }
  func setDelay(_ text: String) throws {
    guard let target = Double(text.components(separatedBy: " ")[0]) else { throw failure("Bad saved delay") }
    for _ in 0..<120 {
      let current = Double(try delayText().components(separatedBy: " ")[0])!
      if abs(current - target) < 0.01 { return }
      try tap(settings, current > target ? ["Decrement", "Decrease"] : ["Increment", "Increase"])
    }
    throw failure("Auto-Answer delay did not converge")
  }
  func enableSystemSettings() throws {
    guard ProcessInfo.processInfo.environment["FOCUS_ALLOW_SYSTEM_SETTINGS"] == "1" else { throw failure("One-time Auto-Answer/Auto-Lock approval flag required") }
    try setup(); try autoLockPage()
    if journal.autoLock == nil { journal.autoLock = try selectedLock(); try save() }
    try tap(settings, ["30 Seconds", "30 seconds"])
    try autoLockPage()
    guard try selectedLock().lowercased() == "30 seconds" else { throw failure("Auto-Lock not 30 seconds") }
    try autoAnswerPage()
    if journal.autoAnswer == nil { journal.autoAnswer = (try answerSwitch().value as? String) == "1"; try save() }
    if (try answerSwitch().value as? String) != "1" { try tap(settings, answerSwitch()) }
    if journal.autoAnswerDelay == nil { journal.autoAnswerDelay = try delayText(); try save() }
    try setDelay("3.0 seconds")
    guard (try answerSwitch().value as? String) == "1" else { throw failure("Auto-Answer not enabled") }
  }
  func restoreSystemSettings() throws {
    if let enabled = journal.autoAnswer {
      try autoAnswerPage()
      if let delay = journal.autoAnswerDelay {
        if (try answerSwitch().value as? String) != "1" { try tap(settings, answerSwitch()) }
        try setDelay(delay)
      }
      if ((try answerSwitch().value as? String) == "1") != enabled { try tap(settings, answerSwitch()) }
      guard ((try answerSwitch().value as? String) == "1") == enabled else { throw failure("Auto-Answer restore failed") }
      journal.autoAnswer = nil; journal.autoAnswerDelay = nil; try save()
    }
    if let value = journal.autoLock {
      try autoLockPage(); try tap(settings, [value]); try autoLockPage()
      guard try selectedLock() == value else { throw failure("Auto-Lock restore failed") }
      journal.autoLock = nil; try save()
    }
  }
  func checkActivity() throws {
    home(); try front(board)
    board.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.01)).press(forDuration: 0.1,
      thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.8)))
    let wanted = ProcessInfo.processInfo.environment["FOCUS_EXPECTED_ACTIVITY_TEXT"] ?? "Synthetic AI call status"
    guard !wanted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, wanted.utf8.count <= 512 else { throw failure("Invalid transcript expectation") }
    _ = try element(board, ["Focus Probe · synthetic transcript"], timeout: 10)
    let card = try element(board, [wanted], timeout: 10)
    guard card.exists else { throw failure("Latest transcript card missing") }
    let screenshot = XCUIScreen.main.screenshot()
    try screenshot.pngRepresentation.write(to: documents.appendingPathComponent("focus-activity.png"), options: .atomic)
    events.append(["event": "activity.card", "expectedText": wanted, "exists": true, "observedAt": Date().timeIntervalSince1970])
    home()
  }
  func observe(_ duration: Double) throws {
    home()
    try JSONSerialization.data(withJSONObject: ["id": ProcessInfo.processInfo.environment["FOCUS_OBSERVATION_ID"] ?? "none"])
      .write(to: documents.appendingPathComponent("focus-ui-ready.json"), options: .atomic)
    let end = Date().addingTimeInterval(min(max(duration, 1), 90))
    var banner = false, fullScreen = false
    var bannerAt: Double?, screenAt: Double?
    repeat {
      if board.state == .runningForeground {
        banner = banner || board.buttons.matching(NSPredicate(format: "label IN %@", ["Accept", "Answer call", "Decline"])).firstMatch.exists
      }
      fullScreen = fullScreen || (callUI.state == .runningForeground && callUI.otherElements["InCallRootView"].exists)
      if banner && bannerAt == nil { bannerAt = Date().timeIntervalSince1970 }
      if fullScreen && screenAt == nil { screenAt = Date().timeIntervalSince1970 }
      Thread.sleep(forTimeInterval: 0.25)
    } while Date() < end
    events.append(["event": "call.observed", "banner": banner, "callScreen": fullScreen,
      "bannerAt": bannerAt.map { $0 as Any } ?? NSNull(), "callScreenAt": screenAt.map { $0 as Any } ?? NSNull(),
      "qualification": "requires-C00", "observedAt": Date().timeIntervalSince1970])
  }
  func testActions() throws {
    continueAfterFailure = false
    let env = ProcessInfo.processInfo.environment
    let state = documents.appendingPathComponent("focus-ui-state.json")
    if let recovery = env["FOCUS_RESTORE_STATE"] {
      guard let data = Data(base64Encoded: recovery) else { throw failure("Invalid recovery encoding") }
      journal = try JSONDecoder().decode(Journal.self, from: data)
    } else if let data = try? Data(contentsOf: state) { journal = try JSONDecoder().decode(Journal.self, from: data) }
    if let caller = env["FOCUS_CALLER"] {
      guard caller.range(of: "^[+][1-9][0-9]{7,14}$", options: .regularExpression) != nil,
        !journal.captured || caller == journal.caller else { throw failure("Caller must match the journaled E.164 identity") }
      journal.caller = caller
    }
    if let name = env["FOCUS_NAME"] {
      guard name.hasPrefix("Focus Probe"), !journal.captured || name == journal.focusName else { throw failure("Use a dedicated Focus Probe profile and matching recovery journal") }
      journal.focusName = name
    }
    guard journal.focusName.hasPrefix("Focus Probe "), journal.focusName.count <= 64,
      journal.contactName.range(of: "^Focus Probe 124 [A-F0-9]{8}$", options: .regularExpression) != nil,
      journal.captured || (!journal.ownsFocus && !journal.ownsContact) else { throw failure("Invalid restoration identity/invariants") }
    let actions = try JSONDecoder().decode([String].self, from: Data((env["FOCUS_ACTIONS"] ?? "[]").utf8))
    guard !actions.isEmpty else { throw failure("No actions supplied") }
    // Validate the entire request before any UI changes. Typos must not mean off/exclude/deny.
    for action in actions {
      let p = action.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
      let values: [String: [String]] = ["focus": ["on", "off"], "app": ["include", "exclude"],
        "person": ["include", "exclude"], "repeated-calls": ["on", "off"], "calls": ["Allowed People Only", "Everyone", "All Contacts", "Favorites", "No One", "Nobody"],
        "policy": ["screenWithAI"], "system-settings": ["enable"], "notifications": ["allow", "deny"], "focus-authorization": ["allow", "deny"]]
      if let allowed = values[p[0]] {
        guard p.count == 2 && allowed.contains(p[1]) else { throw failure("Invalid action value") }
      } else if p[0] == "observe" {
        guard p.count == 2, let n = Double(p[1]), n.isFinite, (1...90).contains(n) else { throw failure("Invalid observation duration") }
      } else {
        guard p.count == 1 && ["setup", "restore-all", "sample", "launch", "home", "terminate", "activity-check"].contains(p[0]) else { throw failure("Unknown action") }
      }
    }
    do {
      for action in actions {
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        let value = parts.count > 1 ? parts[1] : ""
        if ["focus", "app", "person", "calls", "policy", "repeated-calls"].contains(parts[0]) {
          try setup()
          guard journal.captured && journal.ownsFocus else { throw failure("Missing Focus ownership journal") }
        }
        switch parts[0] {
        case "setup": try setup()
        case "focus": try setFocus(journal.focusName, enabled: value == "on")
        case "app": try setMember("Apps", include: value == "include")
        case "person": try setMember("People", include: value == "include")
        case "calls": try setCalls(value)
        case "repeated-calls": try setRepeatedCalls(value == "on")
        case "policy": try setPolicy()
        case "restore-all": try restore()
        case "system-settings": try enableSystemSettings()
        case "activity-check": try checkActivity()
        case "notifications": try authorize(false, allow: value == "allow")
        case "focus-authorization": try authorize(true, allow: value == "allow")
        case "sample": probe.activate(); try tap(probe, ["focus.sample"])
        case "launch": probe.terminate(); probe.launch()
        case "terminate": probe.terminate(); home()
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
