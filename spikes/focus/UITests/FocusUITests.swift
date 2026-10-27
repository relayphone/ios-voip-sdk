import XCTest

// English UI selectors are deliberately fail-closed. A generic build does not qualify them on iOS.
final class FocusUITests: XCTestCase {
  let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
  let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
  let contacts = XCUIApplication(bundleIdentifier: "com.apple.MobileAddressBook")
  let phone = XCUIApplication(bundleIdentifier: "com.apple.mobilephone")
  let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
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
    // Pending restoration markers are saved before any built-in DND mutation.
    var dndAppAllowed: Bool?
    var dndCalls: String?
    var dndRepeated: Bool?
    var ownsFavorite: Bool? // nil decodes journals created by earlier versions
    var liveActivitiesEnabled: Bool?
    var liveActivitiesFrequent: Bool?
    var activityPreview: String?
    var activityWiFi: Bool?
    var activityCellularData: Bool?
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
  // This check is deliberately read-only: never change the user's cross-device preference.
  func verifyShareAcrossDevicesOff() throws {
    try openFocusList()
    let item = settings.switches["Share Across Devices"]
    guard item.waitForExistence(timeout: 4) else { throw failure("Share Across Devices switch unavailable") }
    try front(settings)
    guard let value = item.value as? String, value == "0" else {
      throw failure("Share Across Devices must be verifiably OFF before changing Focus")
    }
    events.append(["event": "shareAcrossDevices.checked", "value": "off", "observedAt": Date().timeIntervalSince1970])
  }
  func setFocus(_ name: String, enabled: Bool, onlyNamedOff: Bool = false) throws {
    try verifyShareAcrossDevicesOff()
    try focusMenu()
    let current = try selectedFocus()
    if (enabled && current != name) || (!enabled && current != nil && (!onlyNamedOff || current == name)) {
      try tap(board, board.buttons["mode-" + (enabled ? name : current!)])
    }
    home(); try focusMenu()
    let actual = try selectedFocus()
    guard enabled ? actual == name : (onlyNamedOff ? actual != name : actual == nil) else { throw failure("Focus toggle did not converge") }
    home()
  }
  func openFocusList() throws {
    settings.terminate(); settings.launch()
    try tap(settings, scrollTo(settings, ["Focus"]))
  }
  func openProfile(_ name: String? = nil) throws {
    try openFocusList(); try tap(settings, scrollTo(settings, [name ?? journal.focusName]))
  }
  var setupVerified = false
  func captureInitialFocus() throws {
    if !journal.captured {
      try verifyShareAcrossDevicesOff()
      try focusMenu(); journal.initialFocus = try selectedFocus(); journal.captured = true; try save(); home()
    }
  }
  // One verified setup per UI session: each check costs a Settings and a Contacts round trip.
  func setup() throws {
    if setupVerified { return }
    try verifyShareAcrossDevicesOff()
    try captureInitialFocus()
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
      try front(contacts)
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
      try front(contacts)
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
  func requireAllowListMode() throws {
    try front(settings)
    let allowed = settings.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR identifier == %@", "Allow Notifications From", "Allow Notifications From")).allElementsBoundByIndex
    let silenced = settings.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR identifier == %@", "Silence Notifications From", "Silence Notifications From")).allElementsBoundByIndex
    func selected(_ elements: [XCUIElement]) -> Bool {
      elements.contains { $0.exists && ($0.isSelected || ($0.value as? String) == "1" || ($0.value as? String) == "Selected") }
    }
    guard selected(allowed) && !selected(silenced) else { throw failure("DND list mode is not verifiably Allow Notifications From") }
  }
  func setMember(_ kind: String, include: Bool, profile: String? = nil) throws {
    try openProfile(profile); try tap(settings, exceptions(kind))
    if profile == nil { try tap(settings, ["Allow Notifications From"]) }
    else { try requireAllowListMode() } // Never change the user's built-in list mode.
    let name = kind == "Apps" ? "Focus Probe" : journal.contactName
    if (try lookup(settings, [name], scan: profile != nil) != nil) != include {
      if include {
        try tap(settings, kind == "Apps" ? ["add-app-button", "Add Apps"] : ["add-person-button", "Add People"])
        let search = settings.searchFields.firstMatch
        if search.waitForExistence(timeout: 2) { try type(settings, search, name) }
        // The People picker keeps the full contact list (same names, unhittable) behind its search results.
        let results = settings.collectionViews["Search results"]
        let hit = results.cells.matching(NSPredicate(format: "label == %@", name)).firstMatch
        let found = hit.waitForExistence(timeout: 4)
        let settled = Date().addingTimeInterval(4)
        while found && !hit.isHittable && Date() < settled { Thread.sleep(forTimeInterval: 0.2) }
        try tap(settings, found ? hit : element(settings, [name], timeout: 5))
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
      while (try lookup(settings, [name], scan: profile != nil) != nil) != include {
        guard Date() < end else { throw failure("\(kind) membership did not converge") }
        Thread.sleep(forTimeInterval: 0.3)
      }
    }
    try commitSheet(); try settle()
    try openProfile(profile); try tap(settings, exceptions(kind))
    if profile != nil { try requireAllowListMode() }
    guard (try lookup(settings, [name], scan: profile != nil) != nil) == include else { throw failure("\(kind) membership did not persist") }
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
  func openPeople(_ profile: String? = nil) throws {
    try openProfile(profile); try tap(settings, exceptions("People"))
    if profile != nil { try requireAllowListMode() }
    if (try? element(settings, ["Cancel"], timeout: 1)) != nil { try commitSheet(); try openProfile(profile); try tap(settings, exceptions("People")); if profile != nil { try requireAllowListMode() } }
  }
  func setCalls(_ value: String, profile: String? = nil) throws {
    try openPeople(profile)
    try tap(settings, scrollTo(settings, ["also-allow-calls-from-group-picker", "Allow Calls From", "Calls From"]))
    try tap(settings, [value]); try settle()
    // Reopen the profile: seeing a menu option is not evidence of its selected value.
    try openPeople(profile)
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
  func setRepeatedCalls(_ enabled: Bool, profile: String? = nil) throws {
    try openPeople(profile)
    _ = try scrollTo(settings, ["Allow Repeated Calls"])
    let item = settings.switches["Allow Repeated Calls"]
    guard ["0", "1"].contains(item.value as? String ?? "") else { throw failure("Repeated-calls state unavailable") }
    guard ((item.value as? String) == "1") != enabled else { return }
    try tap(settings, item); try settle()
    try openPeople(profile); _ = try scrollTo(settings, ["Allow Repeated Calls"])
    guard ((settings.switches["Allow Repeated Calls"].value as? String) == "1") == enabled else { throw failure("Repeated-calls toggle failed") }
  }
  func configureDND() throws {
    try verifyShareAcrossDevicesOff()
    try captureInitialFocus()
    let profile = "Do Not Disturb"
    if journal.dndAppAllowed == nil {
      try openProfile(profile); try tap(settings, exceptions("Apps")); try requireAllowListMode()
      journal.dndAppAllowed = try lookup(settings, ["Focus Probe"], scan: true) != nil
      try save()
    }
    try setMember("Apps", include: false, profile: profile)
    if journal.dndCalls == nil {
      try openPeople(profile)
      let picker = try scrollTo(settings, ["also-allow-calls-from-group-picker"])
      let value = picker.label
      guard ["Allowed People Only", "Everyone", "All Contacts", "Contacts Only", "Favorites", "No One", "Nobody"].contains(value) else {
        throw failure("Cannot snapshot DND Allow Calls From")
      }
      journal.dndCalls = value; try save()
    }
    try setCalls("Allowed People Only", profile: profile)
    if journal.dndRepeated == nil {
      try openPeople(profile); _ = try scrollTo(settings, ["Allow Repeated Calls"])
      let value = settings.switches["Allow Repeated Calls"].value as? String
      guard value == "0" || value == "1" else { throw failure("Cannot snapshot DND repeated-calls switch") }
      journal.dndRepeated = value == "1"; try save()
    }
    try setRepeatedCalls(false, profile: profile)
  }
  func restoreDND() throws {
    let profile = "Do Not Disturb"
    if journal.dndRepeated != nil || journal.dndCalls != nil || journal.dndAppAllowed != nil { try verifyShareAcrossDevicesOff() }
    if let value = journal.dndRepeated {
      try setRepeatedCalls(value, profile: profile); journal.dndRepeated = nil; try save()
    }
    if let value = journal.dndCalls {
      try setCalls(value, profile: profile); journal.dndCalls = nil; try save()
    }
    if let value = journal.dndAppAllowed {
      try setMember("Apps", include: value, profile: profile); journal.dndAppAllowed = nil; try save()
    }
  }
  func verifyUnknownCaller(_ value: String?) throws {
    guard let value, value.range(of: "^[+][1-9][0-9]{7,14}$", options: .regularExpression) != nil,
      value != journal.caller else { throw failure("FOCUS_UNKNOWN_CALLER must be a different owned E.164 number") }
    contacts.terminate(); contacts.launch(); try discardDraft()
    for _ in 0..<4 where !contacts.searchFields.firstMatch.exists {
      guard let back = try? element(contacts, ["Contacts", "Back", "Lists"], timeout: 1) else { break }
      try tap(contacts, back)
    }
    let search = contacts.searchFields.firstMatch
    guard search.waitForExistence(timeout: 4) else { throw failure("Contacts search unavailable for unknown-caller check") }
    let digits = value.filter(\.isNumber)
    // Check the full normalized number and its national suffix. Any hit is unsafe/ambiguous.
    for query in Set([value, digits, String(digits.suffix(10))]) {
      try type(contacts, search, query); Thread.sleep(forTimeInterval: 1)
      let results = contacts.collectionViews["Search results"]
      guard results.waitForExistence(timeout: 4) else { throw failure("Unknown-caller search results unavailable") }
      try front(contacts)
      guard results.cells.count == 0 else { throw failure("Unknown caller search matched a contact") }
      // An empty collection while indexing is not proof of absence: require an explicit settled empty state.
      guard (try? element(contacts, ["No Results", "No Results Found", "No Contacts"], timeout: 4)) != nil else {
        throw failure("Cannot verify Contacts finished the unknown-caller search")
      }
      try front(contacts)
      guard results.cells.count == 0 else { throw failure("Unknown caller search matched a contact") }
    }
    events.append(["event": "unknownCaller.verified", "absentFromContacts": true, "observedAt": Date().timeIntervalSince1970])
  }
  func favoriteRow() throws -> XCUIElement? {
    phone.terminate(); phone.launch()
    try tap(phone, ["Favorites", "Favourites"])
    for _ in 0..<6 { try front(phone); phone.swipeDown() }
    var previous = ""
    for _ in 0..<16 {
      try front(phone)
      let cells = phone.cells.allElementsBoundByIndex
      let matches = cells.filter { $0.exists && $0.label.contains(journal.contactName) }
      guard matches.count <= 1 else { throw failure("Ambiguous owned favorite rows") }
      if let match = matches.first { return match }
      let visible = cells.filter(\.isHittable).map(\.label).joined(separator: "|")
      if visible.isEmpty {
        let empty = phone.staticTexts.matching(NSPredicate(format: "label IN %@", ["No Favorites", "No Favourites"])).firstMatch
        guard empty.exists else { throw failure("Cannot verify empty Favorites list") }
        return nil
      }
      if visible == previous { return nil }
      previous = visible; phone.swipeUp()
    }
    throw failure("Favorites list coverage incomplete")
  }
  func setFavorite(_ enabled: Bool) throws {
    guard journal.ownsContact else { throw failure("Favorite operations require the owned test contact") }
    let existing = try favoriteRow()
    if (existing != nil) == enabled {
      if enabled && journal.ownsFavorite != true { throw failure("Will not claim an unowned favorite") }
      if !enabled && journal.ownsFavorite == true { journal.ownsFavorite = false; try save() }
      return
    }
    if enabled {
      guard try openContact() else { throw failure("Owned test contact unavailable") }
      journal.ownsFavorite = true; try save() // Recovery may remove only this owned contact's favorite.
      try tap(contacts, scrollTo(contacts, ["Add to Favorites", "Add to Favourites"]))
      if let choice = try? element(contacts, ["Call"], timeout: 2) { try tap(contacts, choice) }
      // If a number picker appears, select only the uniquely matching test number.
      let suffix = String(journal.caller.filter(\.isNumber).suffix(10))
      let numberOptions = contacts.buttons.allElementsBoundByIndex.filter { $0.exists && $0.label.filter(\.isNumber).hasSuffix(suffix) }
      guard numberOptions.count <= 1 else { throw failure("Ambiguous test-contact favorite number") }
      if let option = numberOptions.first { try tap(contacts, option) }
      guard try favoriteRow() != nil else { throw failure("Owned contact not visible in Favorites") }
    } else {
      guard journal.ownsFavorite == true, let existing else { throw failure("Will not delete an unowned favorite") }
      try front(phone); existing.swipeLeft(); try front(phone)
      let delete = phone.buttons.matching(NSPredicate(format: "label IN %@", ["Delete", "Remove"])).allElementsBoundByIndex.filter {
        $0.exists && $0.isHittable && existing.frame.intersects($0.frame)
      }
      guard delete.count == 1 else { throw failure("Owned favorite delete control unavailable") }
      try tap(phone, delete[0])
      guard try favoriteRow() == nil else { throw failure("Owned favorite still present") }
      journal.ownsFavorite = false; try save()
    }
    events.append(["event": "favorite.verified", "enabled": enabled, "observedAt": Date().timeIntervalSince1970])
  }
  func restore() throws {
    guard journal.captured else { return }
    try restoreActivitySettings()
    try restoreSystemSettings()
    try restoreDND()
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
      if journal.ownsFavorite == true { try setFavorite(false) }
      if try openContact() {
        try tap(contacts, ["Edit"]); try tap(contacts, scrollTo(contacts, ["Delete Contact"]))
        try tap(contacts, ["Delete Contact", "Delete"])
        guard try !openContact() else { throw failure("Test contact still present") }
      }
      journal.ownsContact = false; try save()
    }
    if let initial = journal.initialFocus { try setFocus(initial, enabled: true) }
    else { try setFocus(journal.focusName, enabled: false) }
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
    guard alert != nil else { throw failure("Authorization prompt missing") }
    let owner = [probe, board].first { $0.state == .runningForeground && $0.alerts.firstMatch.exists }
    guard let owner else { throw failure("Authorization prompt owner is not foreground") }
    let labels = allow ? ["Allow"] : ["Don’t Allow", "Don't Allow"]
    let button = owner.alerts.firstMatch.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    guard button.exists && button.isHittable else { throw failure("Authorization choice missing") }
    try tap(owner, button)
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
  // New ActivityKit Settings selectors have not yet been qualified on a device.
  // Each mutation saves the original value first and fails if it cannot be read back.
  func openUniqueProbeSettingsRow() throws {
    let search = settings.searchFields.firstMatch
    for _ in 0..<4 where !search.exists { try front(settings); settings.swipeDown() }
    guard search.waitForExistence(timeout: 4) else { throw failure("App settings search unavailable; cannot verify unique target") }
    try type(settings, search, "Focus Probe")
    Thread.sleep(forTimeInterval: 1)
    try front(settings)
    let exact = NSPredicate(format: "label == %@ OR identifier == %@", "Focus Probe", "Focus Probe")
    let cells = settings.cells.allElementsBoundByIndex.filter {
      $0.exists && $0.isHittable && ($0.label == "Focus Probe" ||
        $0.descendants(matching: .any).matching(exact).allElementsBoundByIndex.contains { $0.exists })
    }
    guard cells.count == 1 else { throw failure("Probe settings row missing or ambiguous") }
    try tap(settings, cells[0])
  }
  func liveActivitiesPage() throws {
    settings.terminate(); settings.launch()
    try tap(settings, scrollTo(settings, ["Apps"]))
    try openUniqueProbeSettingsRow()
    try tap(settings, scrollTo(settings, ["Live Activities"]))
  }
  func liveSwitch(_ names: [String]) throws -> XCUIElement {
    try front(settings)
    let predicate = NSPredicate(format: "label IN %@ OR identifier IN %@", names, names)
    let candidates = settings.switches.matching(predicate).allElementsBoundByIndex.filter { $0.exists }
    guard candidates.count == 1, ["0", "1"].contains(candidates[0].value as? String ?? "") else {
      throw failure("Live Activity switch unavailable or ambiguous: \(names.joined(separator: "/"))")
    }
    return candidates[0]
  }
  func activitySwitchValue(_ names: [String]) throws -> Bool {
    (try liveSwitch(names).value as? String) == "1"
  }
  func setActivitySwitch(_ names: [String], enabled: Bool) throws {
    let item = try liveSwitch(names)
    if ((item.value as? String) == "1") != enabled {
      try tap(settings, item)
      let deadline = Date().addingTimeInterval(4)
      while (item.value as? String) != (enabled ? "1" : "0"), Date() < deadline {
        try front(settings); Thread.sleep(forTimeInterval: 0.2)
      }
    }
    guard try activitySwitchValue(names) == enabled else { throw failure("Live Activity setting did not converge") }
  }
  func activityEnabled(_ enabled: Bool) throws {
    try captureInitialFocus()
    try liveActivitiesPage()
    let names = ["Allow Live Activities"]
    if journal.liveActivitiesEnabled == nil { journal.liveActivitiesEnabled = try activitySwitchValue(names); try save() }
    try setActivitySwitch(names, enabled: enabled)
    try liveActivitiesPage()
    guard try activitySwitchValue(names) == enabled else { throw failure("Live Activity setting did not persist") }
    events.append(["event": "activity.setting", "setting": "enabled", "value": enabled])
  }
  func activityFrequent(_ enabled: Bool) throws {
    // The frequent-update control may be hidden while activity permission is off.
    // Snapshot and restore the permission separately before temporarily enabling it.
    try activityEnabled(true)
    try liveActivitiesPage()
    let names = ["More Frequent Updates", "Frequent Updates"]
    if journal.liveActivitiesFrequent == nil { journal.liveActivitiesFrequent = try activitySwitchValue(names); try save() }
    try setActivitySwitch(names, enabled: enabled)
    try liveActivitiesPage()
    guard try activitySwitchValue(names) == enabled else { throw failure("Frequent updates setting did not persist") }
    events.append(["event": "activity.setting", "setting": "frequent", "value": enabled])
  }
  func activityPreviewPage() throws {
    settings.terminate(); settings.launch()
    try tap(settings, scrollTo(settings, ["Notifications"]))
    try openUniqueProbeSettingsRow()
    try tap(settings, scrollTo(settings, ["Show Previews"]))
  }
  func selectedActivityPreview() throws -> String {
    try front(settings)
    let choices = ["Default", "Always", "When Unlocked", "Never"]
    let values = settings.descendants(matching: .any).allElementsBoundByIndex.filter {
      choices.contains($0.label) && ($0.isSelected || ($0.value as? String) == "1" || ($0.value as? String) == "Selected")
    }
    let selected = Set(values.map(\.label))
    guard selected.count == 1, let value = selected.first else { throw failure("Cannot snapshot the app preview setting") }
    return value
  }
  func activityPreview(_ value: String) throws {
    try captureInitialFocus()
    try activityPreviewPage()
    if journal.activityPreview == nil { journal.activityPreview = try selectedActivityPreview(); try save() }
    if try selectedActivityPreview() != value { try tap(settings, [value]) }
    try activityPreviewPage()
    guard try selectedActivityPreview() == value else { throw failure("Preview setting did not persist") }
    events.append(["event": "activity.preview", "value": value, "scope": "app notifications; not a Live Activity privacy guarantee"])
  }
  func networkSettingsPage(_ kind: String) throws {
    settings.terminate(); settings.launch()
    let names = kind == "wifi" ? ["Wi-Fi"] : ["Cellular", "Mobile Service", "Mobile Data"]
    try tap(settings, scrollTo(settings, names))
  }
  func networkSwitchNames(_ kind: String) -> [String] {
    kind == "wifi" ? ["Wi-Fi"] : ["Cellular Data", "Mobile Data"]
  }
  func setNetworkSwitch(_ kind: String, enabled: Bool) throws {
    try networkSettingsPage(kind)
    let names = networkSwitchNames(kind)
    try setActivitySwitch(names, enabled: enabled)
    try networkSettingsPage(kind)
    guard try activitySwitchValue(names) == enabled else { throw failure("\(kind) setting did not persist") }
  }
  func activityOffline() throws {
    guard ProcessInfo.processInfo.environment["FOCUS_USB_VERIFIED"] == "1" else {
      throw failure("A currently verified wired device connection is required before disabling network settings")
    }
    try captureInitialFocus()
    // Both original values are saved before either radio setting is changed.
    try networkSettingsPage("wifi")
    if journal.activityWiFi == nil { journal.activityWiFi = try activitySwitchValue(networkSwitchNames("wifi")); try save() }
    try networkSettingsPage("cellular")
    if journal.activityCellularData == nil { journal.activityCellularData = try activitySwitchValue(networkSwitchNames("cellular")); try save() }
    try setNetworkSwitch("cellular", enabled: false)
    try setNetworkSwitch("wifi", enabled: false)
    try networkSettingsPage("cellular")
    guard try !activitySwitchValue(networkSwitchNames("cellular")) else { throw failure("Cellular Data did not remain off") }
    try networkSettingsPage("wifi")
    guard try !activitySwitchValue(networkSwitchNames("wifi")) else { throw failure("Wi-Fi did not remain off") }
    events.append(["event": "activity.networkSettings", "wifi": false, "cellularData": false,
                   "uptimeMs": Int(ProcessInfo.processInfo.systemUptime * 1000),
                   "qualification": "Settings readback only; Ethernet and actual reachability not established"])
  }
  func restoreActivityNetwork() throws {
    if let value = journal.activityCellularData {
      try setNetworkSwitch("cellular", enabled: value)
      journal.activityCellularData = nil; try save()
    }
    if let value = journal.activityWiFi {
      try setNetworkSwitch("wifi", enabled: value)
      journal.activityWiFi = nil; try save()
    }
  }
  func restoreActivitySettings() throws {
    // Restore connectivity first; recovery is allowed even if the original USB
    // verification is no longer available.
    try restoreActivityNetwork()
    if let preview = journal.activityPreview {
      try activityPreviewPage()
      if try selectedActivityPreview() != preview { try tap(settings, [preview]) }
      try activityPreviewPage()
      guard try selectedActivityPreview() == preview else { throw failure("Preview setting restore failed") }
      journal.activityPreview = nil; try save()
    }
    if let frequent = journal.liveActivitiesFrequent {
      try liveActivitiesPage()
      // Enabled state was saved before it was changed; preserve it through recovery.
      guard journal.liveActivitiesEnabled != nil else { throw failure("Missing Live Activity permission restore journal") }
      try setActivitySwitch(["Allow Live Activities"], enabled: true)
      try liveActivitiesPage()
      try setActivitySwitch(["More Frequent Updates", "Frequent Updates"], enabled: frequent)
      try liveActivitiesPage()
      guard try activitySwitchValue(["More Frequent Updates", "Frequent Updates"]) == frequent else { throw failure("Frequent updates restore failed") }
      journal.liveActivitiesFrequent = nil; try save()
    }
    if let enabled = journal.liveActivitiesEnabled {
      try liveActivitiesPage()
      try setActivitySwitch(["Allow Live Activities"], enabled: enabled)
      try liveActivitiesPage()
      guard try activitySwitchValue(["Allow Live Activities"]) == enabled else { throw failure("Live Activity permission restore failed") }
      journal.liveActivitiesEnabled = nil; try save()
    }
  }
  func invokeActivityShortcut() throws {
    shortcuts.activate()
    guard shortcuts.wait(for: .runningForeground, timeout: 8) else { throw failure("Shortcuts did not become foreground") }
    try front(shortcuts)
    guard probe.state != .runningForeground else { throw failure("Probe must be outside foreground before shortcut invocation") }
    try tap(shortcuts, scrollTo(shortcuts, ["App Shortcuts"]))
    try tap(shortcuts, scrollTo(shortcuts, ["Focus Probe"]))
    let shortcut = try scrollTo(shortcuts, ["Start transcript", "Start Focus transcript probe"])
    let before = probe.state
    guard before == .notRunning || before == .runningBackground || before == .runningBackgroundSuspended else {
      throw failure("Probe is foreground or its state is unknown before shortcut invocation")
    }
    let tapStart = Int(ProcessInfo.processInfo.systemUptime * 1000)
    try tap(shortcuts, shortcut)
    // Tapping the system shortcut is not proof of activity creation. The host
    // must verify the token, activity identity and the subsequent trace separately.
    let tapEnd = Int(ProcessInfo.processInfo.systemUptime * 1000)
    events.append(["event": "activity.shortcutInvoked", "source": "Shortcuts UI", "tapStartUptimeMs": tapStart, "uptimeMs": tapEnd,
                   "observedAt": Date().timeIntervalSince1970])
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    var samples = 0, firstSample = 0
    repeat {
      let state: String
      switch probe.state {
      case .notRunning: state = "notRunning"
      case .runningBackground: state = "background"
      case .runningBackgroundSuspended: state = "backgroundSuspended"
      case .runningForeground: state = "foreground"
      case .unknown: state = "unknown"
      @unknown default: state = "unknown"
      }
      let sampledAt = Int(ProcessInfo.processInfo.systemUptime * 1000)
      if samples == 0 { firstSample = sampledAt }
      events.append(["event": "activity.shortcutProbeState", "state": state, "uptimeMs": sampledAt])
      samples += 1
      guard state != "foreground" && state != "unknown" else { throw failure("Probe entered foreground or could not be sampled during shortcut") }
      Thread.sleep(forTimeInterval: 0.2)
    } while ProcessInfo.processInfo.systemUptime < deadline
    events.append(["event": "activity.shortcutObservation", "startUptimeMs": tapStart, "tapEndUptimeMs": tapEnd,
                   "firstSampleUptimeMs": firstSample,
                   "endUptimeMs": Int(ProcessInfo.processInfo.systemUptime * 1000),
                   "samples": samples, "allNonForeground": true, "qualification": "sampled; foreground between samples cannot be excluded"])
  }
  func activityConsent() throws {
    home(); try front(board)
    board.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.01)).press(forDuration: 0.1,
      thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.8)))
    _ = try element(board, ["Focus Probe · synthetic transcript"], timeout: 10)
    for _ in 0..<3 {
      let prompt = board.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Live Activities from Focus Probe")).firstMatch
      if !prompt.exists { home(); return }
      let allow = board.buttons.matching(NSPredicate(format: "identifier == %@ AND label IN %@", "swipe-action-button-identifier", ["Always Allow", "Allow"])).firstMatch
      guard allow.exists else { throw failure("Live Activity consent prompt without Allow") }
      try tap(board, allow); Thread.sleep(forTimeInterval: 1)
    }
    throw failure("Live Activity consent did not clear")
  }
  func openNotificationCenter() throws {
    home(); try front(board)
    board.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.01)).press(forDuration: 0.1,
      thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.8)))
    try front(board)
  }
  func requireNotificationCenterMarker() throws {
    _ = try element(board, ["Notification Center", "No Older Notifications", "No Notifications"], timeout: 5)
  }
  func saveActivityScreenshot(_ event: String, fields: [String: Any] = [:]) throws {
    try front(board)
    let screenshot = XCUIScreen.main.screenshot()
    try screenshot.pngRepresentation.write(to: documents.appendingPathComponent("focus-activity.png"), options: .atomic)
    var record = fields
    record["event"] = event; record["observedAt"] = Date().timeIntervalSince1970
    events.append(record)
  }
  func identifiedActivityCard() throws -> XCUIElement {
    try front(board)
    let title = "Focus Probe · synthetic transcript"
    _ = try element(board, [title], timeout: 3)
    let screen = board.frame
    let candidates = board.cells.allElementsBoundByIndex.filter { cell in
      guard cell.exists && cell.isHittable && cell.frame.width >= screen.width * 0.4 &&
        cell.frame.height >= 40 && cell.frame.height <= screen.height * 0.4 else { return false }
      let labels = cell.staticTexts.allElementsBoundByIndex.filter { $0.exists }.map(\.label)
      let titles = labels.filter { $0 == title }
      let revisions = labels.filter { $0.range(of: "^Revision [0-9]+$", options: .regularExpression) != nil }
      let content = labels.filter { $0 != title && $0 != "Focus Probe" && !revisions.contains($0) }
      return titles.count == 1 && revisions.count == 1 && content.count == 1 &&
        (content[0].hasPrefix("Synthetic") || content[0] == "Updates delayed")
    }
    guard candidates.count == 1, let card = candidates.first else { throw failure("Synthetic activity cell missing or ambiguous") }
    return card
  }
  func respondActivityClockRequest(_ lastNonce: inout String?) throws {
    let requestURL = documents.appendingPathComponent("activity-clock-request.json")
    guard let data = try? Data(contentsOf: requestURL), data.count <= 1024,
      let value = try? JSONSerialization.jsonObject(with: data) as? [String: String],
      let id = value["id"], id == ProcessInfo.processInfo.environment["FOCUS_OBSERVATION_ID"], UUID(uuidString: id) != nil,
      let nonce = value["nonce"], UUID(uuidString: nonce) != nil, nonce != lastNonce else { return }
    // The device timestamp is captured after the host's request was read and
    // before the response is written, providing a bounded round-trip estimate.
    let uptime = Int(ProcessInfo.processInfo.systemUptime * 1000)
    let wall = Int(Date().timeIntervalSince1970 * 1000)
    try JSONSerialization.data(withJSONObject: ["id": id, "nonce": nonce, "uptimeMs": uptime, "wallTimeMs": wall])
      .write(to: documents.appendingPathComponent("activity-clock-response.json"), options: .atomic)
    lastNonce = nonce
  }
  func observeActivity(_ duration: Double) throws {
    guard duration.isFinite && (1...180).contains(duration) else { throw failure("Invalid activity observation duration") }
    guard let observationID = ProcessInfo.processInfo.environment["FOCUS_OBSERVATION_ID"],
      let parsedID = UUID(uuidString: observationID), parsedID.uuidString.lowercased() == observationID else {
      throw failure("Invalid activity observation ID")
    }
    try openNotificationCenter()
    let started = Int(ProcessInfo.processInfo.systemUptime * 1000)
    let deadline = Date().addingTimeInterval(duration)
    var previous = "", count = 0, ready = false
    var lastClockNonce: String?
    repeat {
      let sampleStart = Int(ProcessInfo.processInfo.systemUptime * 1000)
      try front(board)
      let card = try identifiedActivityCard()
      let labels = card.staticTexts.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.map(\.label)
      let revisions = labels.compactMap { value -> Int? in
        guard value.hasPrefix("Revision ") else { return nil }
        return Int(value.dropFirst("Revision ".count))
      }
      guard revisions.count == 1 else { throw failure("Synthetic activity revision is missing or ambiguous") }
      // Match the complete accessibility label within the uniquely identified
      // card. Never export that label (or accept a truncated prefix) as evidence.
      let revision = revisions[0]
      let allLabels = card.staticTexts.allElementsBoundByIndex.filter { $0.exists }.map(\.label)
      let exactMatch = exactCadenceMatch(observationID: observationID, revision: revision,
                                         allLabels: allLabels, visibleLabels: labels)
      try front(board)
      let ended = Int(ProcessInfo.processInfo.systemUptime * 1000)
      let wallTimeMs = Int(Date().timeIntervalSince1970 * 1000)
      let text = labels.filter { $0 != "Focus Probe · synthetic transcript" && !$0.hasPrefix("Revision ") }
        .map { String($0.prefix(512)) }
      guard text.count <= 10 else { throw failure("Ambiguous synthetic activity text") }
      let stale = text.contains("Updates delayed")
      let signature = "\(revision)|\(stale)|\(exactMatch)|" + text.joined(separator: "|")
      events.append(["event": "activity.sample", "revision": revisions[0], "stale": stale,
                     "sampleStartUptimeMs": sampleStart, "uptimeMs": ended, "wallTimeMs": wallTimeMs])
      if signature != previous {
        // Only a Boolean is exported: labels may include other notification
        // content if a system accessibility ancestor is broader than expected.
        events.append(["event": "activity.renderSample", "revision": revisions[0],
                       "syntheticTextVisible": text.contains(where: { $0.hasPrefix("Synthetic") }),
                       "syntheticExactMatch": exactMatch, "observationID": observationID,
                       "stale": stale, "sampleStartUptimeMs": sampleStart, "uptimeMs": ended, "wallTimeMs": wallTimeMs])
        previous = signature
      }
      count += 1
      if !ready {
        let id = ProcessInfo.processInfo.environment["FOCUS_OBSERVATION_ID"] ?? "none"
        try JSONSerialization.data(withJSONObject: ["id": id, "startUptimeMs": started,
                                                    "uptimeMs": ended, "wallTimeMs": wallTimeMs])
          .write(to: documents.appendingPathComponent("activity-observation-ready.json"), options: .atomic)
        ready = true
      }
      try respondActivityClockRequest(&lastClockNonce)
      if Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
    } while Date() < deadline
    let ended = Int(ProcessInfo.processInfo.systemUptime * 1000)
    try saveActivityScreenshot("activity.observed", fields: ["startUptimeMs": started, "endUptimeMs": ended,
      "samples": count, "qualification": "rendering only; no audio or wake conclusion"])
    home()
  }
  func activityAbsent() throws {
    try openNotificationCenter()
    // Absence on an unrecognized screen is not evidence. Require an explicit
    // Notification Center marker before checking the card.
    try requireNotificationCenterMarker()
    let title = "Focus Probe · synthetic transcript"
    let empty = board.staticTexts.matching(NSPredicate(format: "label == %@", "No Notifications"))
      .allElementsBoundByIndex.contains { $0.exists && $0.isHittable }
    if empty {
      let query = board.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR identifier == %@", title, title))
      guard !query.allElementsBoundByIndex.contains(where: { $0.exists }) else { throw failure("Live Activity card is still present") }
    } else {
      // Scroll the loaded list to a stable end; an incomplete list is not an absence.
      guard try lookup(board, [title], scan: true) == nil else { throw failure("Live Activity card is still present") }
    }
    try requireNotificationCenterMarker()
    try saveActivityScreenshot("activity.absent", fields: ["notificationCenterVerified": true])
    home()
  }
  func activityTextVisibility(_ expected: Bool?) throws {
    try openNotificationCenter()
    let card = try identifiedActivityCard()
    let wanted = ProcessInfo.processInfo.environment["FOCUS_EXPECTED_ACTIVITY_TEXT"] ?? ""
    guard !wanted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, wanted.utf8.count <= 512 else {
      throw failure("Invalid synthetic activity expectation")
    }
    let query = card.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", wanted))
    let found = query.allElementsBoundByIndex.contains { $0.exists && $0.isHittable }
    if let expected, found != expected { throw failure("Activity text visibility differs from expectation") }
    // Record only whether the synthetic marker is visible, never arbitrary text.
    try saveActivityScreenshot("activity.textVisibility", fields: ["visible": found])
    home()
  }
  func activityDismiss() throws {
    try openNotificationCenter()
    let title = "Focus Probe · synthetic transcript"
    let marker = ProcessInfo.processInfo.environment["FOCUS_EXPECTED_ACTIVITY_TEXT"] ?? ""
    let prefix = "Synthetic dismissal "
    guard marker.hasPrefix(prefix), UUID(uuidString: String(marker.dropFirst(prefix.count))) != nil else {
      throw failure("A unique synthetic dismissal marker is required")
    }
    try front(board)
    let candidates = board.cells.allElementsBoundByIndex.filter { cell in
      guard cell.exists && cell.isHittable else { return false }
      let labels = cell.staticTexts.allElementsBoundByIndex.filter { $0.exists }.map(\.label)
      let titles = labels.filter { $0 == title }
      let revisions = labels.filter { $0.range(of: "^Revision [0-9]+$", options: .regularExpression) != nil }
      let content = labels.filter { $0 != title && $0 != "Focus Probe" && !revisions.contains($0) }
      // A dedicated cell must contain exactly one target title/revision and
      // one run-unique synthetic message, with no unrelated notification text.
      return titles.count == 1 && revisions.count == 1 && content.count == 1 && content[0] == marker
    }
    guard candidates.count == 1, let card = candidates.first else { throw failure("Probe activity cell is missing, ambiguous or contains unrelated text") }
    let originalFrame = card.frame
    try front(board); card.swipeLeft(); try front(board)
    let titleQuery = board.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR identifier == %@", title, title))
    func titleVisible() -> Bool { titleQuery.allElementsBoundByIndex.contains { $0.exists } }
    if titleVisible() {
      // Only an action within the identified card's own frame may be tapped.
      let buttons = board.buttons.matching(NSPredicate(format: "label IN %@", ["Clear", "Dismiss", "Remove"]))
        .allElementsBoundByIndex.filter { $0.exists && $0.isHittable && originalFrame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
      guard buttons.count == 1 else { throw failure("Specific Live Activity dismissal control unavailable") }
      try tap(board, buttons[0])
    }
    let deadline = Date().addingTimeInterval(5)
    while titleVisible() && Date() < deadline { try front(board); Thread.sleep(forTimeInterval: 0.2) }
    try front(board)
    guard !titleVisible() else { throw failure("Live Activity dismissal was not observed") }
    try requireNotificationCenterMarker()
    // The disappearance is a UI observation. The app must separately verify
    // ActivityKit state and registration cleanup.
    try saveActivityScreenshot("activity.dismissed", fields: ["observation": "UI card disappeared"])
    home()
  }
  func checkActivity() throws {
    home(); try front(board)
    board.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.01)).press(forDuration: 0.1,
      thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.8)))
    let wanted = ProcessInfo.processInfo.environment["FOCUS_EXPECTED_ACTIVITY_TEXT"] ?? "Synthetic AI call status"
    guard !wanted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, wanted.utf8.count <= 512 else { throw failure("Invalid transcript expectation") }
    _ = try element(board, ["Focus Probe · synthetic transcript"], timeout: 10)
    // iOS 27 asks inline on the probe's first card before it shows its Live Activities. A push sent before
    // consent cannot qualify the row: grant it for this disposable probe and fail so the row is rerun.
    // Two stages were seen: "Allow Live Activities from …?" then "… continue to allow …?" (Always Allow).
    if board.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Live Activities from Focus Probe")).firstMatch.exists {
      let allow = board.buttons.matching(NSPredicate(format: "identifier == %@ AND label IN %@", "swipe-action-button-identifier", ["Always Allow", "Allow"])).firstMatch
      guard allow.exists else { throw failure("Live Activity consent prompt without Allow") }
      try tap(board, allow); Thread.sleep(forTimeInterval: 1)
      throw failure("Live Activity consent was pending; granted it, rerun the row")
    }
    let card = try element(board, [wanted], timeout: 10)
    guard card.exists else { throw failure("Latest transcript card missing") }
    let screenshot = XCUIScreen.main.screenshot()
    try screenshot.pngRepresentation.write(to: documents.appendingPathComponent("focus-activity.png"), options: .atomic)
    events.append(["event": "activity.card", "expectedText": wanted, "exists": true, "observedAt": Date().timeIntervalSince1970])
    home()
  }
  // Match only exact synthetic caller identity inside the currently visible call surface.
  // An inaccessible, ambiguous or differently formatted identity is deliberately false.
  func callerMatches(_ scope: XCUIElement, app: XCUIApplication, expected: String) -> Bool {
    guard app.state == .runningForeground, scope.exists else { return false }
    let names = ["Focus Test Caller", expected].filter { !$0.isEmpty }
    let predicate = NSPredicate(format: "label IN %@ OR identifier IN %@", names, names)
    let matched = scope.descendants(matching: .any).matching(predicate).allElementsBoundByIndex
      .contains { $0.exists && $0.isHittable }
    return app.state == .runningForeground && matched
  }
  func bannerCallerMatches(expected: String) -> Bool {
    guard board.state == .runningForeground else { return false }
    let controls = ["Accept", "Answer call", "Decline"]
    // Reject full-screen ancestors: the caller and call button must share a compact banner container.
    let containers = board.descendants(matching: .any)
      .containing(NSPredicate(format: "label IN %@ OR identifier IN %@", controls, controls)).allElementsBoundByIndex
    let limit = min(board.frame.height * 0.4, 250)
    for item in containers where item.exists && item.frame.height > 0 && item.frame.height <= limit {
      let buttons = item.buttons.matching(NSPredicate(format: "label IN %@ OR identifier IN %@", controls, controls))
      if buttons.allElementsBoundByIndex.contains(where: { $0.exists && $0.isHittable }),
         callerMatches(item, app: board, expected: expected) { return true }
    }
    return false
  }
  func observe(_ duration: Double) throws {
    home()
    let startedUptimeMs = Int(ProcessInfo.processInfo.systemUptime * 1000)
    let end = Date().addingTimeInterval(min(max(duration, 1), 240))
    var banner = false, fullScreen = false
    var bannerAt: Double?, screenAt: Double?
    var previousBanner = false, previousScreen = false
    var previousBannerCaller = false, previousScreenCaller = false
    var readyPublished = false
    let expected = ProcessInfo.processInfo.environment["FOCUS_EXPECTED_CALLER"] ?? ""
    guard expected.utf8.count <= 128 else { throw failure("Invalid expected caller") }
    repeat {
      let sampleStartUptimeMs = Int(ProcessInfo.processInfo.systemUptime * 1000)
      let boardIsFront = board.state == .runningForeground
      let callIsFront = callUI.state == .runningForeground
      guard boardIsFront || callIsFront else { throw failure("Call surfaces cannot be sampled without a recognized foreground app") }
      var currentBanner = false
      if boardIsFront {
        currentBanner = board.buttons.matching(NSPredicate(format: "label IN %@", ["Accept", "Answer call", "Decline"])).firstMatch.exists
      }
      let currentScreen = callIsFront && callUI.otherElements["InCallRootView"].exists
      let bannerCaller = currentBanner && bannerCallerMatches(expected: expected)
      let screenCaller = currentScreen && callerMatches(callUI.otherElements["InCallRootView"], app: callUI, expected: expected)
      guard boardIsFront == (board.state == .runningForeground), callIsFront == (callUI.state == .runningForeground) else {
        throw failure("Foreground app changed while sampling call surfaces")
      }
      let now = Date().timeIntervalSince1970
      let uptimeMs = Int(ProcessInfo.processInfo.systemUptime * 1000)
      events.append(["event": "surface.sample", "surface": "banner", "visible": currentBanner, "callerMatched": bannerCaller, "observedAt": now, "uptimeMs": uptimeMs, "sampleStartUptimeMs": sampleStartUptimeMs])
      events.append(["event": "surface.sample", "surface": "callScreen", "visible": currentScreen, "callerMatched": screenCaller, "observedAt": now, "uptimeMs": uptimeMs, "sampleStartUptimeMs": sampleStartUptimeMs])
      if currentBanner != previousBanner || bannerCaller != previousBannerCaller {
        events.append(["event": "surface.transition", "surface": "banner", "visible": currentBanner, "callerMatched": bannerCaller, "observedAt": now, "uptimeMs": uptimeMs, "sampleStartUptimeMs": sampleStartUptimeMs])
      }
      if currentScreen != previousScreen || screenCaller != previousScreenCaller {
        events.append(["event": "surface.transition", "surface": "callScreen", "visible": currentScreen, "callerMatched": screenCaller, "observedAt": now, "uptimeMs": uptimeMs, "sampleStartUptimeMs": sampleStartUptimeMs])
      }
      previousBanner = currentBanner; previousScreen = currentScreen
      previousBannerCaller = bannerCaller; previousScreenCaller = screenCaller
      if !readyPublished {
        // No push may be sent until the observer has captured both baseline surfaces.
        try JSONSerialization.data(withJSONObject: ["id": ProcessInfo.processInfo.environment["FOCUS_OBSERVATION_ID"] ?? "none"])
          .write(to: documents.appendingPathComponent("focus-ui-ready.json"), options: .atomic)
        readyPublished = true
      }
      banner = banner || currentBanner; fullScreen = fullScreen || currentScreen
      if banner && bannerAt == nil { bannerAt = Date().timeIntervalSince1970 }
      if fullScreen && screenAt == nil { screenAt = Date().timeIntervalSince1970 }
      Thread.sleep(forTimeInterval: 0.25)
    } while Date() < end
    events.append(["event": "call.observed", "banner": banner, "callScreen": fullScreen,
      "bannerAt": bannerAt.map { $0 as Any } ?? NSNull(), "callScreenAt": screenAt.map { $0 as Any } ?? NSNull(),
      "qualification": "requires-C00", "observedAt": Date().timeIntervalSince1970,
      "startUptimeMs": startedUptimeMs, "endUptimeMs": Int(ProcessInfo.processInfo.systemUptime * 1000)])
  }
  // Read-only accessibility trees for selector work, written to the runner's Documents.
  func dump(_ name: String) throws {
    var text = ""
    switch name {
    case "controlcenter":
      home(); Thread.sleep(forTimeInterval: 1); try front(board); openControlCenter(); text = board.debugDescription
    case "focusmenu":
      try focusMenuOpenOnly(); Thread.sleep(forTimeInterval: 1.5); text = board.debugDescription
    case "settings-focus":
      settings.terminate(); settings.launch(); Thread.sleep(forTimeInterval: 1)
      if let item = try? scrollTo(settings, ["Focus"]) { try tap(settings, item) }
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
    try front(board); openControlCenter()
    let tile = board.buttons["focus-module"]
    if tile.waitForExistence(timeout: 3) { try tap(board, tile) }
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
        "policy": ["screenWithAI"], "system-settings": ["enable", "restore"], "notifications": ["allow", "deny"], "focus-authorization": ["allow", "deny"],
        "share-across-devices": ["check"], "dnd": ["on", "off", "configure"], "unknown": ["verify"], "favorite": ["on", "off"],
        "activity-setting": ["enable", "disable", "frequent-on", "frequent-off"], "activity-preview": ["always", "unlocked", "never"],
        "activity-network": ["offline", "restore"]]
      if let allowed = values[p[0]] {
        guard p.count == 2 && allowed.contains(p[1]) else { throw failure("Invalid action value") }
      } else if p[0] == "dump" {
        guard p.count == 2 else { throw failure("Invalid dump") }
      } else if p[0] == "observe" || p[0] == "activity-observe" {
        guard p.count == 2, let n = Double(p[1]), n.isFinite, n >= 1,
          n <= (p[0] == "activity-observe" ? 180.0 : 240.0) else { throw failure("Invalid observation duration") }
      } else {
        guard p.count == 1 && ["setup", "restore-all", "sample", "launch", "home", "terminate", "activity-consent", "activity-check", "activity-absent", "activity-contains", "activity-hidden", "activity-probe-text", "activity-shortcut", "activity-dismiss", "lock"].contains(p[0]) else { throw failure("Unknown action") }
      }
    }
    do {
      for action in actions {
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        let value = parts.count > 1 ? parts[1] : ""
        if ["focus", "app", "person", "calls", "policy", "repeated-calls"].contains(parts[0]) {
          try setup()
          guard journal.captured && journal.ownsFocus else { throw failure("Missing Focus ownership journal") }
          try verifyShareAcrossDevicesOff()
        }
        switch parts[0] {
        case "setup": try setup()
        case "focus": try setFocus(journal.focusName, enabled: value == "on")
        case "share-across-devices": try verifyShareAcrossDevicesOff(); try save()
        case "dnd":
          if value == "configure" { try configureDND() }
          else { try captureInitialFocus(); try setFocus("Do Not Disturb", enabled: value == "on", onlyNamedOff: true) }
        case "unknown": try verifyUnknownCaller(env["FOCUS_UNKNOWN_CALLER"])
        case "favorite": try setup(); try setFavorite(value == "on")
        case "app": try setMember("Apps", include: value == "include")
        case "person": try setMember("People", include: value == "include")
        case "calls": try setCalls(value)
        case "repeated-calls": try setRepeatedCalls(value == "on")
        case "policy": try setPolicy()
        case "restore-all": try restore()
        case "system-settings": try value == "enable" ? enableSystemSettings() : restoreSystemSettings()
        case "activity-check": try checkActivity()
        case "activity-observe": try observeActivity(Double(value) ?? 0)
        case "activity-consent": try activityConsent()
        case "activity-absent": try activityAbsent()
        case "activity-contains": try activityTextVisibility(true)
        case "activity-hidden": try activityTextVisibility(false)
        case "activity-probe-text": try activityTextVisibility(nil)
        case "activity-shortcut": try invokeActivityShortcut()
        case "activity-dismiss": try activityDismiss()
        case "activity-setting":
          if value == "enable" || value == "disable" { try activityEnabled(value == "enable") }
          else { try activityFrequent(value == "frequent-on") }
        case "activity-preview":
          let modes = ["always": "Always", "unlocked": "When Unlocked", "never": "Never"]
          guard let mode = modes[value] else { throw failure("Invalid preview option") }
          try activityPreview(mode)
        case "activity-network": try value == "offline" ? activityOffline() : restoreActivityNetwork()
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
