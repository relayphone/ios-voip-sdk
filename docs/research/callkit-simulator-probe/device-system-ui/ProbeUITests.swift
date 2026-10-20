import XCTest

// Operates the genuine CallKit system UI while the probe app scripts calls (PROBE_MODE=ui).
final class ProbeUITests: XCTestCase {
  let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
  let inCall = XCUIApplication(bundleIdentifier: "com.apple.InCallService")
  let probe = XCUIApplication(bundleIdentifier: "dev.callkitsim.probe")
  let t0 = Date()

  func log(_ text: String) { print("UITRACE \(Int(Date().timeIntervalSince(t0) * 1000)) \(text)") }

  func dump(_ name: String) {
    for (label, app) in [("springboard", springboard), ("incallservice", inCall), ("probe", probe)] {
      let state = app.state
      log("dump \(name) \(label) state=\(state.rawValue)")
      guard state != .notRunning, state != .unknown else { continue }
      let text = app.debugDescription
      print("=== DUMP \(name) \(label)\n\(text)\n=== END DUMP")
    }
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "\(name)-screen"
    shot.lifetime = .keepAlways
    add(shot)
  }

  struct Hit { let label: String; let identifier: String; let type: XCUIElement.ElementType; let point: CGPoint; let host: String; var element: XCUIElement? = nil }

  // One accessibility snapshot per poll: reading it can fail without failing the test.
  func find(_ labels: [String], kinds: [XCUIElement.ElementType] = [.button], timeout: TimeInterval) -> Hit? {
    let wanted = Set(labels.map { $0.lowercased() })
    let screen = CGSize(width: 390, height: 844)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      // SpringBoard: element queries include the remote banner; its snapshot does not.
      for kind in kinds {
        for l in labels {
          let el = springboard.descendants(matching: kind).matching(NSPredicate(format: "label ==[c] %@ OR identifier ==[c] %@", l, l)).firstMatch
          if el.exists {
            log("found '\(l)' kind=\(kind.rawValue) in springboard")
            return Hit(label: l, identifier: l, type: kind, point: .zero, host: "springboard", element: el)
          }
        }
      }
      for host in [inCall, probe] {
        let state = host.state
        guard state == .runningForeground || state == .runningBackground else { continue }
        guard let root = try? host.snapshot() else { continue }
        // InCallService frames are screen coordinates only while its root fills the screen.
        var fullScreen = host !== inCall
        var stack: [XCUIElementSnapshot] = [root]
        var found: XCUIElementSnapshot?
        while let node = stack.popLast() {
          if node.identifier == "InCallRootView", node.frame.origin == .zero, node.frame.width >= screen.width * 0.9, node.frame.height >= screen.height * 0.9 { fullScreen = true }
          if found == nil, kinds.contains(node.elementType), node.frame.width > 0,
             wanted.contains(node.label.lowercased()) || wanted.contains(node.identifier.lowercased()) { found = node }
          stack.append(contentsOf: node.children)
        }
        if let node = found, fullScreen {
          let point = CGPoint(x: node.frame.midX, y: node.frame.midY)
          log("found '\(node.label)' id=\(node.identifier) type=\(node.elementType.rawValue) in \(name(host)) frame=\(node.frame)")
          return Hit(label: node.label, identifier: node.identifier, type: node.elementType, point: point, host: name(host))
        }
      }
      Thread.sleep(forTimeInterval: 0.25)
    }
    log("not found \(labels)")
    return nil
  }

  func name(_ host: XCUIApplication) -> String { host === springboard ? "springboard" : host === inCall ? "incallservice" : "probe" }

  func press(_ hit: Hit) {
    if let el = hit.element { el.tap(); log("tapped \(hit.label) via springboard element"); return }
    if hit.host == "incallservice" {
      let key = hit.identifier.isEmpty ? hit.label : hit.identifier
      let el = inCall.buttons[key].firstMatch
      if el.exists { el.tap(); log("tapped \(key) via incallservice element"); return }
    }
    springboard.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: hit.point.x, dy: hit.point.y)).tap()
    log("tapped \(hit.label) at \(hit.point)")
  }

  @discardableResult
  func tap(_ labels: [String], timeout: TimeInterval, dumpAs: String? = nil) -> Bool {
    guard let hit = find(labels, timeout: timeout) else { if let dumpAs { dump("missing-\(dumpAs)") }; return false }
    if let dumpAs { dump(dumpAs) }
    press(hit)
    return true
  }

  func testSystemCallUI() throws {
    continueAfterFailure = true
    probe.launchEnvironment = ["PROBE_MODE": "ui"]
    probe.launch()
    log("launched")

    tap(["Accept"], timeout: 30, dumpAs: "1-incoming-banner")
    Thread.sleep(forTimeInterval: 3); dump("1-after-accept")

    tap(["Hold & Accept"], timeout: 60, dumpAs: "2-waiting")
    Thread.sleep(forTimeInterval: 3); dump("2-after-hold-accept")

    tap(["End & Accept"], timeout: 60, dumpAs: "3-waiting")
    Thread.sleep(forTimeInterval: 3); dump("3-after-end-accept")

    // Decline only a waiting call: wait for the waiting-call choices first.
    if find(["Hold & Accept", "End & Accept"], timeout: 60) != nil { tap(["Decline"], timeout: 5, dumpAs: "4-waiting-decline") }
    Thread.sleep(forTimeInterval: 4)

    XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
    log("locked")
    if let hit = find(["Accept", "Answer call", "slide to answer", "Slide to answer"], kinds: [.button, .slider, .other], timeout: 60) {
      dump("5-locked-incoming")
      if hit.type == .slider || hit.label.lowercased().contains("slide") {
        let origin = springboard.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: 60, dy: hit.point.y)).press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 360, dy: hit.point.y)))
        log("slid to answer")
      } else { press(hit) }
    } else { dump("5-locked-missing") }
    Thread.sleep(forTimeInterval: 3); dump("5-locked-incall")
    for (step, labels) in [("mute", ["Mute"]), ("keypad", ["Keypad"]), ("digit", ["5"]), ("hide", ["Hide", "Done", "Keypad"]),
                           ("speaker", ["Speaker", "Audio"]), ("more", ["More"])] {
      if tap(labels, timeout: 6) { Thread.sleep(forTimeInterval: 2); dump("5-after-\(step)") }
    }
    XCUIDevice.shared.press(.home)  // dismiss a More menu if open
    Thread.sleep(forTimeInterval: 1)
    tap(["End", "End call"], timeout: 8, dumpAs: "5-before-end")
    Thread.sleep(forTimeInterval: 3)
    XCUIDevice.shared.press(.home); Thread.sleep(forTimeInterval: 1); XCUIDevice.shared.press(.home)
    log("unlock attempted")
    Thread.sleep(forTimeInterval: 1); dump("5-after-unlock")

    tap(["Accept"], timeout: 60, dumpAs: "6-background-banner")
    Thread.sleep(forTimeInterval: 3); dump("6-after-background-accept")

    log("done")
  }
}
