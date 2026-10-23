import ExpoModulesCore
import Foundation
import QuartzCore
import os

func handlerNow() -> Double { CACurrentMediaTime() * 1000 }
@Record struct HandlerWire: Sendable {
  let id: String
  let runtime: String
  let kind: String
  let sentMs: Double
  let dueMs: Double
}
@Record struct HandlerReport: Sendable {
  var id: String
  var runtime: String
  var outcome: String
  var sentMs: Double
  var dueMs: Double
  var enteredMs: Double
  var settledMs: Double
  var finishedMs: Double
  var returnedMs: Double
  var abortedMs: Double
  var created: Int
  var resumes: Int
  var returned: Int
  var late: Int
}
@Record struct HandlerSnapshot: Sendable {
  let runtime: String
  let checkpoint: String
  let reloads: Int
  let pending: Int
  let cases: [HandlerReport]
}
final class HandlerLedger: Sendable {
  static let shared = HandlerLedger()
  private struct Entry: Sendable {
    var report: HandlerReport
    let cell: HandlerCell<String>?
    var timer: Task<Void, Never>?
    var emit: (@Sendable (HandlerWire) -> Void)?
  }
  private struct State: Sendable {
    var registered = Set<String>()
    var cases: [String: Entry] = [:]
    var checkpoint = ""
    var reloads = 0
  }
  private let state = OSAllocatedUnfairLock(initialState: State())
  private init() {
    // Process-lifetime observer: synchronous native cancellation precedes RCTHost teardown.
    _ = NotificationCenter.default.addObserver(forName: .init("RCTTriggerReloadCommandNotification"), object: nil, queue: nil) { [weak self] _ in
      guard let self else { return }
      let keys = self.state.withLock { state in
        state.reloads += 1; state.registered.removeAll()
        return state.cases.filter { $0.value.report.outcome == "pending" }.map(\.key)
      }
      for key in keys { _ = self.finish(key, outcome: "reload") }
    }
  }
  func register(_ runtime: String, enabled: Bool) {
    state.withLock { if enabled { $0.registered.insert(runtime) } else { $0.registered.remove(runtime) } }
  }
  func checkpoint(_ value: String) { state.withLock { $0.checkpoint = value } }
  func start(_ id: String, runtime: String, timeout: Double, emit: @escaping @Sendable (HandlerWire) -> Void) {
    let key = runtime + ":" + id, now = handlerNow()
    let cell = state.withLock { state -> HandlerCell<String>? in
      guard state.cases[key] == nil else { return nil }
      let registered = state.registered.contains(runtime)
      let cell = registered ? HandlerCell<String>() : nil
      let report = HandlerReport(id: id, runtime: runtime, outcome: registered ? "pending" : "default-fail", sentMs: now,
        dueMs: registered ? now + timeout : 0, enteredMs: 0, settledMs: 0, finishedMs: registered ? 0 : handlerNow(),
        returnedMs: registered ? 0 : handlerNow(), abortedMs: 0, created: 0, resumes: 0, returned: registered ? 0 : 1, late: 0)
      state.cases[key] = Entry(report: report, cell: cell, timer: nil, emit: registered ? emit : nil)
      return cell
    }
    guard let cell else { return } // No handler: native default, no continuation/timer/JS dispatch.
    Task.detached {
      _ = await cell.wait()
      let returned = handlerNow()
      self.state.withLock { $0.cases[key]?.report.returned += 1; $0.cases[key]?.report.returnedMs = returned }
    }
    let timer = Task.detached { [weak self] in
      do { try await Task.sleep(for: .milliseconds(max(0, now + timeout - handlerNow()))) } catch { return }
      _ = self?.finish(key, outcome: "deadline")
    }
    let active = state.withLock { state in
      guard state.cases[key]?.report.outcome == "pending" else { return false }
      state.cases[key]?.timer = timer
      return true
    }
    if active { emit(HandlerWire(id: id, runtime: runtime, kind: "invoke", sentMs: now, dueMs: now + timeout)) }
    else { timer.cancel() }
  }
  @discardableResult func finish(_ key: String, outcome: String, settled: Double = 0) -> Bool {
    let terminal = state.withLock { state -> Entry? in
      guard var entry = state.cases[key] else { return nil }
      guard entry.report.outcome == "pending" else { state.cases[key]?.report.late += 1; return nil }
      entry.report.outcome = outcome; entry.report.settledMs = settled; entry.report.finishedMs = handlerNow()
      state.cases[key] = entry
      state.cases[key]?.timer = nil; state.cases[key]?.emit = nil
      return entry
    }
    guard let terminal else { return false }
    terminal.timer?.cancel()
    if outcome == "deadline" {
      terminal.emit?(HandlerWire(id: terminal.report.id, runtime: terminal.report.runtime, kind: "cancel",
        sentMs: terminal.report.finishedMs, dueMs: terminal.report.dueMs))
    }
    terminal.cell?.finish(outcome) // Resume outside the ledger lock.
    return true
  }
  func mark(_ id: String, runtime: String, at: Double, abort: Bool) {
    state.withLock { state in
      if abort { state.cases[runtime + ":" + id]?.report.abortedMs = at }
      else { state.cases[runtime + ":" + id]?.report.enteredMs = at }
    }
  }
  func snapshot(_ runtime: String) -> HandlerSnapshot {
    state.withLock { state in
      let reports = state.cases.values.map { entry in
        var report = entry.report
        let counts = entry.cell?.stats ?? [0, 0]
        report.created = counts[0]; report.resumes = counts[1]
        return report
      }.sorted { $0.id < $1.id }
      return HandlerSnapshot(runtime: runtime, checkpoint: state.checkpoint, reloads: state.reloads,
        pending: reports.filter { $0.outcome == "pending" }.count, cases: reports)
    }
  }
}
