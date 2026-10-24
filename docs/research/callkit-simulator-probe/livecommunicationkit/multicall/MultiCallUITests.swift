import XCTest

// Operates the genuine system call UI for one multi-call row while lckmulti.swift scripts the calls.
// run.sh passes the row through TEST_RUNNER_MULTI_ROW and its UI steps through TEST_RUNNER_MULTI_UI
// (a JSON array such as ["launch", "accept", "holdAccept", "done:120"]). "?" before a step makes it optional.
final class MultiCallUITests: XCTestCase {
  let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
  let inCall = XCUIApplication(bundleIdentifier: "com.apple.InCallService")
  let probe = XCUIApplication(bundleIdentifier: "dev.callkitsim.probe")
  let contacts = XCUIApplication(bundleIdentifier: "com.apple.MobileAddressBook")
  let t0 = Date()

  func log(_ text: String) { print("UITRACE \(Int(Date().timeIntervalSince(t0) * 1000)) \(text)") }

  func dump(_ name: String, apps: [(String, XCUIApplication)]? = nil) {
    for (label, app) in apps ?? [("springboard", springboard), ("incallservice", inCall), ("probe", probe)] {
      let state = app.state
      log("dump \(name) \(label) state=\(state.rawValue)")
      guard state != .notRunning, state != .unknown else { continue }
      print("=== DUMP \(name) \(label)\n\(app.debugDescription)\n=== END DUMP")
    }
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "\(name)-screen"
    shot.lifetime = .keepAlways
    add(shot)
  }

  struct Hit { let label: String; let identifier: String; let point: CGPoint; let host: String; var element: XCUIElement? = nil }

  // Same search as ProbeUITests: SpringBoard element queries include the remote banner; InCallService
  // frames are screen coordinates only while its root fills the screen.
  func find(_ labels: [String], timeout: TimeInterval) -> Hit? {
    let wanted = Set(labels.map { $0.lowercased() })
    let screen = CGSize(width: 390, height: 844)
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      for l in labels {
        let el = springboard.buttons.matching(NSPredicate(format: "label ==[c] %@ OR identifier ==[c] %@", l, l)).firstMatch
        if el.exists { log("found '\(l)' in springboard"); return Hit(label: l, identifier: l, point: .zero, host: "springboard", element: el) }
      }
      let state = inCall.state
      if state == .runningForeground || state == .runningBackground, let root = try? inCall.snapshot() {
        var fullScreen = false
        var stack: [XCUIElementSnapshot] = [root]
        var found: XCUIElementSnapshot?
        while let node = stack.popLast() {
          if node.identifier == "InCallRootView", node.frame.origin == .zero, node.frame.width >= screen.width * 0.9,
             node.frame.height >= screen.height * 0.9 { fullScreen = true }
          if found == nil, node.elementType == .button, node.frame.width > 0,
             wanted.contains(node.label.lowercased()) || wanted.contains(node.identifier.lowercased()) { found = node }
          stack.append(contentsOf: node.children)
        }
        if let node = found, fullScreen {
          log("found '\(node.label)' id=\(node.identifier) in incallservice frame=\(node.frame)")
          return Hit(label: node.label, identifier: node.identifier, point: CGPoint(x: node.frame.midX, y: node.frame.midY), host: "incallservice")
        }
      }
      Thread.sleep(forTimeInterval: 0.25)
    } while Date() < deadline
    log("not found \(labels)")
    return nil
  }

  func press(_ hit: Hit) {
    if let el = hit.element { el.tap(); log("tapped \(hit.label) via springboard element"); return }
    let key = hit.identifier.isEmpty ? hit.label : hit.identifier
    let el = inCall.buttons[key].firstMatch
    if el.exists { el.tap(); log("tapped \(key) via incallservice element"); return }
    springboard.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: hit.point.x, dy: hit.point.y)).tap()
    log("tapped \(hit.label) at \(hit.point)")
  }

  // Taps the first label found; dumps the screen first so each choice screen's labels are recorded.
  @discardableResult
  func tap(_ labels: [String], timeout: TimeInterval, as name: String) -> Bool {
    guard let hit = find(labels, timeout: timeout) else { dump("missing-\(name)"); return false }
    dump(name)
    press(hit)
    return true
  }

  // MARK: Contacts block list (row filter-block only; restored by filter-unblock)

  let blockName = "LCK Block Probe", blockNumber = "+15555550199"

  func element(_ app: XCUIApplication, _ labels: [String], timeout: TimeInterval = 8) -> XCUIElement? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      for l in labels {
        let el = app.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] %@ OR identifier ==[c] %@", l, l)).firstMatch
        if el.exists && el.isHittable { return el }
      }
      Thread.sleep(forTimeInterval: 0.3)
    } while Date() < deadline
    log("contacts: not found \(labels)")
    return nil
  }

  func scrollTo(_ app: XCUIApplication, _ labels: [String]) -> XCUIElement? {
    for _ in 0..<6 {
      if let el = element(app, labels, timeout: 1.5) { return el }
      app.swipeUp()
    }
    return nil
  }

  func openBlockContact() -> Bool {
    contacts.activate()
    guard let search = element(contacts, ["Search"], timeout: 10) else { dump("contacts-no-search", apps: [("contacts", contacts)]); return false }
    search.tap(); search.typeText(blockName)
    guard let cell = element(contacts, [blockName], timeout: 8) else { dump("contacts-no-result", apps: [("contacts", contacts)]); return false }
    cell.tap()
    return true
  }

  func contactsBlock() -> Bool {
    contacts.terminate(); contacts.launch()
    guard let add = element(contacts, ["Add", "Add Contact", "New Contact"], timeout: 10) else {
      dump("contacts-no-add", apps: [("contacts", contacts)]); return false
    }
    add.tap()
    guard let first = element(contacts, ["First name"], timeout: 8) else { dump("contacts-no-first", apps: [("contacts", contacts)]); return false }
    first.tap(); first.typeText(blockName)
    guard let addPhone = scrollTo(contacts, ["add phone", "Add phone", "add phone number"]) else {
      dump("contacts-no-add-phone", apps: [("contacts", contacts)]); return false
    }
    addPhone.tap()
    contacts.typeText(blockNumber)
    dump("contacts-filled", apps: [("contacts", contacts)])
    guard let done = element(contacts, ["Done"]) else { dump("contacts-no-done", apps: [("contacts", contacts)]); return false }
    done.tap()
    guard let block = scrollTo(contacts, ["Block Caller", "Block this Caller", "Block Contact"]) else {
      dump("contacts-no-block", apps: [("contacts", contacts)]); return false
    }
    block.tap()
    guard let confirm = element(contacts, ["Block Contact", "Block"], timeout: 8) else {
      dump("contacts-no-confirm", apps: [("contacts", contacts)]); return false
    }
    confirm.tap()
    let blocked = scrollTo(contacts, ["Unblock Caller", "Unblock this Caller", "Unblock Contact"]) != nil
    dump("contacts-blocked", apps: [("contacts", contacts)])
    log("contacts: blocked=\(blocked)")
    return blocked
  }

  func contactsUnblock() -> Bool {
    contacts.terminate(); contacts.launch()
    guard openBlockContact() else { return false }
    if let unblock = scrollTo(contacts, ["Unblock Caller", "Unblock this Caller", "Unblock Contact"]) { unblock.tap(); log("contacts: unblocked") }
    guard let edit = element(contacts, ["Edit"]) else { dump("contacts-no-edit", apps: [("contacts", contacts)]); return false }
    edit.tap()
    guard let delete = scrollTo(contacts, ["Delete Contact"]) else { dump("contacts-no-delete", apps: [("contacts", contacts)]); return false }
    delete.tap()
    guard let confirm = element(contacts, ["Delete Contact", "Delete"], timeout: 8) else {
      dump("contacts-no-delete-confirm", apps: [("contacts", contacts)]); return false
    }
    confirm.tap()
    Thread.sleep(forTimeInterval: 1)
    contacts.terminate(); contacts.launch()
    let remaining = element(contacts, [blockName], timeout: 2) != nil
    log("contacts: deleted remaining=\(remaining)")
    dump("contacts-after-delete", apps: [("contacts", contacts)])
    XCUIDevice.shared.press(.home)
    return !remaining
  }

  // MARK: Row driver

  func waitDone(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if probe.state == .runningForeground {
        let status = probe.staticTexts["multi.status"]
        if status.exists, status.label.hasPrefix("DONE") { log("probe \(status.label)"); return }
      }
      Thread.sleep(forTimeInterval: 1)
    }
    log("probe not DONE after \(Int(seconds)) s (the host checks the trace)")
  }

  func testRow() throws {
    continueAfterFailure = true
    let env = ProcessInfo.processInfo.environment
    let row = env["MULTI_ROW"] ?? "smoke"
    let steps = (env["MULTI_UI"].flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] }) ?? ["launch", "dump:smoke"]
    log("row \(row) steps \(steps)")
    var failures: [String] = []
    for raw in steps {
      let optional = raw.hasPrefix("?")
      let step = optional ? String(raw.dropFirst()) : raw
      let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
      let arg = parts.count > 1 ? parts[1] : ""
      let ok: Bool
      switch parts[0] {
      case "launch": probe.launch(); log("launched"); ok = true
      case "accept": ok = tap(["Accept", "Answer call"], timeout: Double(arg) ?? 30, as: "accept")
      case "holdAccept": ok = tap(["Hold & Accept"], timeout: Double(arg) ?? 45, as: "hold-accept")
      case "endAccept": ok = tap(["End & Accept"], timeout: Double(arg) ?? 45, as: "end-accept")
      case "decline": ok = tap(["Decline"], timeout: Double(arg) ?? 30, as: "decline")
      case "swap": ok = tap(["Swap", "Swap calls"], timeout: Double(arg) ?? 10, as: "swap")
      case "merge":
        ok = tap(["Merge", "Merge calls", "Merge Calls"], timeout: Double(arg) ?? 8, as: "merge")
          || (tap(["More"], timeout: 5, as: "more") && tap(["Merge", "Merge calls", "Merge Calls"], timeout: 5, as: "merge-in-more"))
      case "end": ok = tap(["End", "End call"], timeout: Double(arg) ?? 10, as: "end")
      case "dismiss": ok = tap(["Cancel", "Dismiss"], timeout: Double(arg) ?? 3, as: "dismiss")  // a leftover "Call failed" screen
      case "choices":
        // Records whichever call-waiting choices the system offers, without tapping.
        let hit = find(["Hold & Accept", "End & Accept", "Decline", "Accept", "Answer call"], timeout: Double(arg) ?? 30)
        dump("choices"); log("choices first=\(hit?.label ?? "none")"); ok = hit != nil
      case "dump": dump(arg.isEmpty ? "dump" : arg); ok = true
      case "wait": Thread.sleep(forTimeInterval: Double(arg) ?? 1); ok = true
      case "lock": XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton")); log("locked"); ok = true
      case "home": XCUIDevice.shared.press(.home); ok = true
      case "contactsBlock": ok = contactsBlock()
      case "contactsUnblock": ok = contactsUnblock()
      case "done": waitDone(Double(arg) ?? 90); ok = true
      default: log("unknown step \(step)"); ok = false
      }
      log("step \(raw) ok=\(ok)")
      if !ok && !optional { failures.append(step) }
    }
    log("row \(row) finished failures=\(failures)")
    XCTAssertTrue(failures.isEmpty, "UI steps failed: \(failures)")
  }
}
