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
    for _ in 0..<10 {
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
    openControlCenter()
    let tile = board.buttons["focus-module"]
    guard tile.waitForExistence(timeout: 3) else { throw failure("Control Center Focus module unavailable") }
    // iOS 27: the module's value names the active Focus and is empty when none is on.
    verifiedFocusOff = !tile.isSelected && (tile.value as? String ?? "").isEmpty
    try tap(board, tile)
    _ = try element(board, ["mode-Do Not Disturb"])
  }
  func modes() -> XCUIElementQuery { board.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mode-")) }
  func selectedFocus() throws -> String? {
    try front(board)
    let selected = modes().allElementsBoundByIndex.filter(\.isSelected)
    guard selected.count <= 1 else { throw failure("Ambiguous active Focus") }
    guard !selected.isEmpty || verifiedFocusOff else { throw failure("Unknown Focus state; no verified Off marker") }
    return selected.first.map { String($0.identifier.dropFirst("mode-".count)) }
  }
  func setFocus(_ name: String, enabled: Bool) throws {
    try focusMenu()
    let current = try selectedFocus()
    if (enabled && current != name) || (!enabled && current != nil) {
      try tap(board, board.buttons["mode-" + (enabled ? name : current!)])
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
  var setupVerified = false
  // One verified setup per UI session: each check costs a Settings and a Contacts round trip.
  func setup() throws {
    if setupVerified { return }
    if !journal.captured {
      try focusMenu(); journal.initialFocus = try selectedFocus(); journal.captured = true; try save(); home()
    }
    try openFocusList()
    if try lookup(settings, [journal.focusName]) != nil {
      guard journal.ownsFocus else { throw failure("Chosen Focus already exists without an ownership journal") }
    } else {
      try tap(settings, ["add", "Add", "Add Focus"]); try tap(settings, ["Custom"])
      let name = settings.textFields.firstMatch
      XCTAssertTrue(name.waitForExistence(timeout: 4)); try type(settings, name, journal.focusName)
      // Persist ownership intent before the creation tap, for interrupted-run restoration.
      journal.ownsFocus = true; try save()
      // The keyboard covers Next on iOS 27's "Name Your Focus" sheet.
      if settings.keyboards.firstMatch.exists { try tap(settings, ["Return", "return", "Done"]); Thread.sleep(forTimeInterval: 0.5) }
      try tap(settings, ["Next"]); try tap(settings, ["Customize Focus", "Customise Focus"])
    }
    if try !openContact() { try createContact() }
    else if !journal.ownsContact { throw failure("Unowned test contact collision") }
    setupVerified = true
  }
  func openContact() throws -> Bool {
    contacts.terminate(); contacts.launch()
    try discardDraft()
    for _ in 0..<4 where !contacts.searchFields.firstMatch.exists {
      guard let back = try? element(contacts, ["Contacts", "Back", "Lists"], timeout: 1) else { break }
      try tap(contacts, back)
    }
    let search = contacts.searchFields.firstMatch
    if !search.waitForExistence(timeout: 4) {
      // After a call Contacts can reopen deep in a card stack; one clean relaunch recovers the list.
      contacts.terminate(); contacts.launch(); try discardDraft()
      guard search.waitForExistence(timeout: 4) else { throw failure("Contacts search unavailable") }
    }
    try type(contacts, search, journal.contactName)
    Thread.sleep(forTimeInterval: 1)
    // The full list behind the search results holds a same-named, unhittable cell: match inside the results only.
    let results = contacts.collectionViews["Search results"]
    guard results.waitForExistence(timeout: 4) else { throw failure("Contacts search results unavailable") }
    let match = results.cells.matching(NSPredicate(format: "label == %@", journal.contactName)).firstMatch
    guard match.waitForExistence(timeout: 3) else { try front(contacts); return false }
    try tap(contacts, match); return true
  }
  // iOS 27 Contacts reopens an interrupted new-contact draft over the list. Only our own draft is discarded.
  func discardDraft() throws {
    Thread.sleep(forTimeInterval: 1)
    for _ in 0..<2 where contacts.navigationBars["Unsaved Draft"].exists || contacts.navigationBars["New Contact"].exists {
      let name = contacts.textFields["First name"].value as? String ?? ""
      let phone = (contacts.textFields["mobile"].value as? String ?? "").filter(\.isNumber)
      let ours = name.hasPrefix("Focus Probe 124") || ((name.isEmpty || name == "First name") && phone == journal.caller.filter(\.isNumber))
      guard ours else { throw failure("Unowned Contacts draft open") }
      try tap(contacts, ["close"])
      if let discard = try? element(contacts, ["Discard Changes", "Discard", "Delete Draft", "Don’t Save", "Don't Save"], timeout: 2) { try tap(contacts, discard) }
      Thread.sleep(forTimeInterval: 1)
    }
  }
  func createContact() throws {
    guard try !openContact() else { throw failure("Test contact name collision") }
    contacts.terminate(); contacts.launch()
    try tap(contacts, ["Add", "Add Contact", "New Contact"])
    // iOS 27 focuses First name at once, and its keyboard covers "add phone": drag the form up above it.
    var addPhone = try? element(contacts, ["add phone", "Add phone"], timeout: 1)
    for _ in 0..<3 where addPhone == nil {
      let form = contacts.tables.firstMatch
      form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05,
        thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
      addPhone = try? element(contacts, ["add phone", "Add phone"], timeout: 1)
    }
    guard let addPhone else { throw failure("add phone stays under the keyboard") }
    try tap(contacts, addPhone)
    Thread.sleep(forTimeInterval: 0.5); try front(contacts); contacts.typeText(journal.caller)
    var first = try? element(contacts, ["First name", "First Name"], timeout: 1)
    for _ in 0..<3 where first == nil {
      let form = contacts.tables.firstMatch
      form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).press(forDuration: 0.05,
        thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
      first = try? element(contacts, ["First name", "First Name"], timeout: 1)
    }
    guard let first else { throw failure("First name not reachable") }
    try type(contacts, first, journal.contactName)
    journal.ownsContact = true; try save()
    try tap(contacts, ["Done"])
    guard try openContact() else { throw failure("Created contact could not be verified") }
  }
  func exceptions(_ kind: String) -> [String] { [kind == "Apps" ? "apps-exceptions-button" : "people-exceptions-button", kind] }
  // iOS 27 first edits People/Apps in a modal sheet that saves only on Done, later in a pushed page that saves
  // live. Either way the short grid needs no scrolling.
  func setMember(_ kind: String, include: Bool) throws {
    try openProfile(); try tap(settings, exceptions(kind))
    // This is a dedicated owned profile; never mutate another Focus's list mode.
    try tap(settings, ["Allow Notifications From"])
    let name = kind == "Apps" ? "Focus Probe" : journal.contactName
    if (try lookup(settings, [name], scan: false) != nil) != include {
      if include {
        try tap(settings, kind == "Apps" ? ["add-app-button", "Add Apps"] : ["add-person-button", "Add People"])
        let search = settings.searchFields.firstMatch
        if search.waitForExistence(timeout: 2) { try type(settings, search, name) }
        // The People picker keeps the full contact list (same names, unhittable) behind its search results.
        let results = settings.collectionViews["Search results"]
        let hit = results.cells.matching(NSPredicate(format: "label == %@", name)).firstMatch
        let settled = Date().addingTimeInterval(4)
        while hit.exists && !hit.isHittable && Date() < settled { Thread.sleep(forTimeInterval: 0.2) }
        try tap(settings, hit.waitForExistence(timeout: 3) ? hit : element(settings, [name], timeout: 5))
        // Both pickers confirm with Done once their search closes (the People picker is multi-select).
        if let done = try? element(settings, ["Done"], timeout: 2) { try tap(settings, done) }
      } else {
        // Exact accessibility names only; no unverified coordinate deletion. The tile itself ignores taps on
        // iOS 27: its "minus" badge, located inside the named tile, removes it.
        let tile = try element(settings, ["Remove, \(name)", "Remove \(name)", "Delete \(name)"])
        let badge = settings.buttons.matching(identifier: "minus").allElementsBoundByIndex.first {
          tile.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
        }
        guard let badge else { throw failure("Remove badge missing for \(name)") }
        try tap(settings, badge)
      }
      let end = Date().addingTimeInterval(4)
      while (try lookup(settings, [name], scan: false) != nil) != include {
        guard Date() < end else { throw failure("\(kind) membership did not converge") }
        Thread.sleep(forTimeInterval: 0.3)
      }
    }
    try commitSheet(); try settle()
    try openProfile(); try tap(settings, exceptions(kind))
    guard (try lookup(settings, [name], scan: false) != nil) == include else { throw failure("\(kind) membership did not persist") }
    if let cancel = try? element(settings, ["Cancel"], timeout: 1) { try tap(settings, cancel) }
  }
  // The first People sheet is two steps (Next, then Done); a pushed page has neither and needs no commit.
  func commitSheet() throws {
    for _ in 0..<3 {
      if let done = try? element(settings, ["Done"], timeout: 2) { try tap(settings, done); Thread.sleep(forTimeInterval: 1); return }
      if let next = try? element(settings, ["Next"], timeout: 2) { try tap(settings, next); Thread.sleep(forTimeInterval: 1); continue }
      // Only the modal sheet has Cancel; leaving it uncommitted would silently drop the edit.
      guard (try? element(settings, ["Cancel"], timeout: 1)) == nil else { throw failure("Focus sheet shows neither Next nor Done") }
      return
    }
    throw failure("Focus sheet did not commit")
  }
  // The pushed page saves asynchronously: leave it and give Settings time before the next relaunch.
  func settle() throws {
    if let back = try? element(settings, ["BackButton"], timeout: 1) { try tap(settings, back) }
    Thread.sleep(forTimeInterval: 2)
  }
  func openPeople() throws {
    try openProfile(); try tap(settings, exceptions("People"))
    if (try? element(settings, ["Cancel"], timeout: 1)) != nil { try commitSheet(); try openProfile(); try tap(settings, exceptions("People")) }
  }
  func setCalls(_ value: String) throws {
    try openPeople()
    try tap(settings, scrollTo(settings, ["also-allow-calls-from-group-picker", "Allow Calls From", "Calls From"]))
    try tap(settings, [value]); try settle()
    // Reopen the profile: seeing a menu option is not evidence of its selected value.
    try openPeople()
    let picker = try scrollTo(settings, ["also-allow-calls-from-group-picker"])
    guard picker.label == value else { throw failure("Allow Calls From stayed \(picker.label)") }
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
    try openPeople()
    _ = try scrollTo(settings, ["Allow Repeated Calls"])
    let item = settings.switches["Allow Repeated Calls"]
    guard ["0", "1"].contains(item.value as? String ?? "") else { throw failure("Repeated-calls state unavailable") }
    guard ((item.value as? String) == "1") != enabled else { return }
    try tap(settings, item); try settle()
    try openPeople(); _ = try scrollTo(settings, ["Allow Repeated Calls"])
    guard ((settings.switches["Allow Repeated Calls"].value as? String) == "1") == enabled else { throw failure("Repeated-calls toggle failed") }
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
    probe.activate()
    // A tap right after launch can be dropped; sample again until the snapshot fills in.
    for _ in 0..<4 {
      try tap(probe, ["focus.sample"])
      let end = Date().addingTimeInterval(2)
      repeat {
        let text = probe.staticTexts["focus.authorization.snapshot"].label
        if let value = try? JSONDecoder().decode([String: Int].self, from: Data(text.utf8)), value.count == 2 { return value }
        Thread.sleep(forTimeInterval: 0.2)
      } while Date() < end
    }
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
    // iOS 27 shows the permission alert in SpringBoard, not in the requesting app.
    let end = Date().addingTimeInterval(6)
    var alert: XCUIElement?
    repeat {
      alert = [probe.alerts.firstMatch, board.alerts.firstMatch].first(where: \.exists)
      if alert == nil { Thread.sleep(forTimeInterval: 0.2) }
    } while alert == nil && Date() < end
    guard let alert else { throw failure("Authorization prompt missing") }
    let labels = allow ? ["Allow"] : ["Don’t Allow", "Don't Allow"]
    let button = alert.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    guard button.exists && button.isHittable else { throw failure("Authorization choice missing") }
    button.tap()
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
  // Settings saves the choice asynchronously; wait for the checkmark and give it time before any relaunch.
  func chooseLock(_ labels: [String]) throws {
    let cell = try element(settings, labels)
    try tap(settings, cell)
    let end = Date().addingTimeInterval(3)
    while !cell.isSelected && Date() < end { Thread.sleep(forTimeInterval: 0.2) }
    Thread.sleep(forTimeInterval: 1.5)
  }
  // XCUIDevice has no public lock button; this test-only private selector is checked before use.
  func lockDevice() throws {
    let selector = NSSelectorFromString("pressLockButton")
    guard XCUIDevice.shared.responds(to: selector) else { throw failure("Lock button unavailable") }
    XCUIDevice.shared.perform(selector)
    Thread.sleep(forTimeInterval: 1)
    events.append(["event": "device.lockPressed", "observedAt": Date().timeIntervalSince1970])
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
  // The Auto-Answer row's centre is its label, which does not toggle; tap the switch itself at the trailing edge.
  func flip(_ item: XCUIElement) throws {
    try front(settings)
    let before = item.value as? String
    item.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    let end = Date().addingTimeInterval(3)
    while (item.value as? String) == before && Date() < end { Thread.sleep(forTimeInterval: 0.2) }
    guard (item.value as? String) != before else { throw failure("Switch did not toggle") }
    Thread.sleep(forTimeInterval: 1)
  }
  func delayText() throws -> String {
    try front(settings)
    // iOS 27 shows the delay as an editable "Seconds" field (value "3.00") between steppers.
    let field = settings.textFields["Seconds"]
    if field.waitForExistence(timeout: 2), let value = field.value as? String, Double(value) != nil { return value + " seconds" }
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
    try chooseLock(["30 Seconds", "30 seconds"])
    try autoLockPage()
    // Measured on iOS 27 under an XCUITest session: the choice shows as selected, then reads back as the
    // previous value. Record it and rely on the explicit "lock" action instead of failing the row.
    let lock = try selectedLock()
    events.append(["event": "autoLock.readback", "value": lock, "observedAt": Date().timeIntervalSince1970])
    try autoAnswerPage()
    if journal.autoAnswer == nil { journal.autoAnswer = (try answerSwitch().value as? String) == "1"; try save() }
    if (try answerSwitch().value as? String) != "1" { try flip(answerSwitch()) }
    if journal.autoAnswerDelay == nil { journal.autoAnswerDelay = try delayText(); try save() }
    try setDelay("3.0 seconds")
    guard (try answerSwitch().value as? String) == "1" else { throw failure("Auto-Answer not enabled") }
  }
  func restoreSystemSettings() throws {
    if let enabled = journal.autoAnswer {
      try autoAnswerPage()
      if let delay = journal.autoAnswerDelay {
        if (try answerSwitch().value as? String) != "1" { try flip(answerSwitch()) }
        try setDelay(delay)
      }
      if ((try answerSwitch().value as? String) == "1") != enabled { try flip(answerSwitch()) }
      guard ((try answerSwitch().value as? String) == "1") == enabled else { throw failure("Auto-Answer restore failed") }
      journal.autoAnswer = nil; journal.autoAnswerDelay = nil; try save()
    }
    if let value = journal.autoLock {
      try autoLockPage(); try chooseLock([value]); try autoLockPage()
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
  // Read-only accessibility trees for selector work, written to the runner's Documents.
  func dump(_ name: String) throws {
    var text = ""
    switch name {
    case "controlcenter":
      home(); Thread.sleep(forTimeInterval: 1); openControlCenter(); text = board.debugDescription
    case "focusmenu":
      try focusMenuOpenOnly(); Thread.sleep(forTimeInterval: 1.5); text = board.debugDescription
    case "settings-focus":
      settings.terminate(); settings.launch(); Thread.sleep(forTimeInterval: 1)
      if let item = try? scrollTo(settings, ["Focus"]) { item.tap() }
      Thread.sleep(forTimeInterval: 1.5); text = settings.debugDescription
    case "screen":
      try XCUIScreen.main.screenshot().pngRepresentation.write(to: documents.appendingPathComponent("focus-dump-screen.png"), options: .atomic)
      text = board.debugDescription
      try text.write(to: documents.appendingPathComponent("focus-dump-screen.txt"), atomically: true, encoding: .utf8); return
    case "settings-root":
      settings.terminate(); settings.launch(); Thread.sleep(forTimeInterval: 1.5); text = settings.debugDescription
    default:
      text = "unknown dump " + name
    }
    try text.write(to: documents.appendingPathComponent("focus-dump-\(name).txt"), atomically: true, encoding: .utf8)
    home()
  }
  // A quick flick: a slow drag ending over a module long-presses it and expands that module (iOS 27).
  func openControlCenter() {
    board.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.005)).press(forDuration: 0.05,
      thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.35)), withVelocity: .fast, thenHoldForDuration: 0)
    Thread.sleep(forTimeInterval: 1.2)
  }
  func focusMenuOpenOnly() throws {
    home(); Thread.sleep(forTimeInterval: 1)
    openControlCenter()
    let tile = board.buttons["focus-module"]
    if tile.waitForExistence(timeout: 3) { tile.tap() }
    Thread.sleep(forTimeInterval: 1.5)
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
        "person": ["include", "exclude"], "repeated-calls": ["on", "off"], "calls": ["Allowed People Only", "Everyone", "All Contacts", "Contacts Only", "Favorites", "No One", "Nobody"],
        "policy": ["screenWithAI"], "system-settings": ["enable", "restore"], "notifications": ["allow", "deny"], "focus-authorization": ["allow", "deny"]]
      if let allowed = values[p[0]] {
        guard p.count == 2 && allowed.contains(p[1]) else { throw failure("Invalid action value") }
      } else if p[0] == "dump" {
        guard p.count == 2 else { throw failure("Invalid dump") }
      } else if p[0] == "observe" {
        guard p.count == 2, let n = Double(p[1]), n.isFinite, (1...90).contains(n) else { throw failure("Invalid observation duration") }
      } else {
        guard p.count == 1 && ["setup", "restore-all", "sample", "launch", "home", "terminate", "activity-check", "lock"].contains(p[0]) else { throw failure("Unknown action") }
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
        case "system-settings": try value == "enable" ? enableSystemSettings() : restoreSystemSettings()
        case "activity-check": try checkActivity()
        case "notifications": try authorize(false, allow: value == "allow")
        case "focus-authorization": try authorize(true, allow: value == "allow")
        case "sample": probe.activate(); try tap(probe, ["focus.sample"])
        case "launch": probe.terminate(); probe.launch()
        case "terminate": probe.terminate(); home()
        case "home": home()
        case "lock": try lockDevice()
        case "observe": try observe(Double(value) ?? 35)
        case "dump": try dump(value)
        default: throw failure("Unknown action \(action)")
        }
        events.append(["action": action, "status": "ok"])
      }
      try writeResult("ok")
    } catch {
      // Exploration aid: keep the front app's tree for selector fixes.
      let app = [settings, contacts, probe, callUI].first(where: { $0.state == .runningForeground }) ?? board
      try? (error.localizedDescription + "\n" + app.debugDescription).write(to: documents.appendingPathComponent("focus-dump-failure.txt"), atomically: true, encoding: .utf8)
      try? writeResult("failed"); throw error
    }
  }
  func writeResult(_ status: String) throws {
    try JSONSerialization.data(withJSONObject: ["status": status, "events": events], options: [.sortedKeys])
      .write(to: documents.appendingPathComponent("focus-ui-result.json"), options: .atomic)
  }
}
