import AVFAudio
import CryptoKit
import Foundation
import SwiftUI

private struct ScalarObservation: Sendable {
  var kind: String
  var contextClass = ""
  var hasSource = false
  var source = 0
  var hasInterruptionReason = false
  var interruptionReason: UInt = 0
  var shouldResume = false
  var fields: [String: Any] {
    ["kind": kind, "contextClass": contextClass, "hasSource": hasSource, "source": source,
     "hasInterruptionReason": hasInterruptionReason, "interruptionReason": interruptionReason,
     "shouldResume": shouldResume]
  }
}

@MainActor
private final class AudioLifecycleProbe: ObservableObject {
  @Published var status = "Ready. Choose the ordinary-session test, then run once."
  @Published var running = false
  @Published private(set) var hasRun = false
  private let consumer = SystemAudioSession() // Unchanged SDK Swift consumer, not a facade.
  private var decoder: VSAudioSessionLifecycleObserver?
  private var tokens: [any NSObjectProtocol] = []
  private var file: FileHandle?
  private var runID = ""
  private var phase = "setup"
  private var sequence = 0
  private let start = ProcessInfo.processInfo.systemUptime
  private var heartbeat: Task<Void, Never>?
  private var ticks = 0
  private var maxTickGapMS = 0.0
  private let privateName = Notification.Name("dev.iosvoipsdk.audio-lifecycle-probe.private-control")

  private func log(_ event: String, _ fields: [String: Any] = [:]) {
    guard let file else { return }
    sequence += 1
    var row = fields
    row.merge(["event": event, "sequence": sequence, "phase": phase, "runID": runID,
      "pid": Int(getpid()), "bundleID": Bundle.main.bundleIdentifier ?? "",
      "main": Thread.isMainThread, "t_ms": Int((ProcessInfo.processInfo.systemUptime - start) * 1000),
      "wallTimeMS": Int(Date().timeIntervalSince1970 * 1000)]) { old, _ in old }
    guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
    try? file.write(contentsOf: data + Data("\n".utf8))
    FileHandle.standardError.write(Data("PROBE ".utf8) + data + Data("\n".utf8))
  }

  nonisolated private static func decoded(_ value: VSAudioSessionLifecycleValue) -> ScalarObservation {
    let kind: String
    switch value.kind {
    case .active: kind = "active"
    case .inactive: kind = "inactive"
    case .resumptionRecommended: kind = "recommended"
    case .mediaServicesReset: kind = "reset"
    @unknown default: kind = "unknown"
    }
    return .init(kind: kind, hasSource: value.hasSource, source: value.source,
      hasInterruptionReason: value.hasInterruptionReason, interruptionReason: value.interruptionReason,
      shouldResume: value.shouldResume)
  }

  @available(iOS 27.0, *)
  nonisolated private static func raw(_ note: Notification) -> ScalarObservation {
    if note.name == AVAudioSession.didBecomeActiveNotification { return .init(kind: "active") }
    if note.name == AVAudioSession.didBecomeInactiveNotification {
      var value = ScalarObservation(kind: "inactive")
      if let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext {
        value.contextClass = NSStringFromClass(type(of: context))
        value.hasSource = true; value.source = context.source.rawValue
        if let interruption = context.interruptionContext {
          value.hasInterruptionReason = true; value.interruptionReason = interruption.reason.rawValue
        }
      }
      return value
    }
    if note.name == AVAudioSession.resumptionRecommendationNotification {
      var value = ScalarObservation(kind: "recommended")
      if let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext {
        value.contextClass = NSStringFromClass(type(of: context)); value.shouldResume = context.recommendation == .shouldResume
      }
      return value
    }
    return .init(kind: note.name == AVAudioSession.routeChangeNotification ? "route" : "legacy")
  }

  @available(iOS 27.0, *)
  private func installObservers() {
    consumer.onLifecycle = { [weak self] event in
      let value: ScalarObservation
      switch event {
      case .active: value = .init(kind: "active")
      case .inactive(let source, let reason):
        value = .init(kind: "inactive", hasSource: source != nil, source: source ?? 0,
          hasInterruptionReason: reason != nil, interruptionReason: reason ?? 0)
      case .resumptionRecommended(let resume): value = .init(kind: "recommended", shouldResume: resume)
      case .mediaServicesReset: value = .init(kind: "reset")
      }
      self?.log("consumer.lifecycle", value.fields) // Actual SystemAudioSession.deliver → onLifecycle.
    }
    decoder = VSAudioSessionLifecycleObserver { [weak self] scalar in
      let value = Self.decoded(scalar)
      MainActor.assumeIsolated { self?.log("decoder.lifecycle", value.fields) }
    }
    let names = [AVAudioSession.didBecomeActiveNotification, AVAudioSession.didBecomeInactiveNotification,
      AVAudioSession.resumptionRecommendationNotification, AVAudioSession.interruptionNotification,
      AVAudioSession.routeChangeNotification]
    for name in names {
      tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        let value = Self.raw(note)
        let name = note.name.rawValue
        MainActor.assumeIsolated {
          var fields = value.fields; fields["notificationName"] = name
          self?.log("raw.notification", fields)
        }
      })
    }
    tokens.append(NotificationCenter.default.addObserver(forName: privateName, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.log("control.privateSentinelReceived", ["syntheticPrivateControl": true, "countsAsAVNotification": false]) }
    })
    log("observers.installed", ["actualSwiftConsumer": true, "independentCDecoder": decoder != nil,
      "rawNotificationNames": names.map(\.rawValue), "tokensRetained": tokens.count])
    log("control.privateSentinelPosted", ["syntheticPrivateControl": true, "countsAsAVNotification": false])
    NotificationCenter.default.post(name: privateName, object: nil) // Private wiring control; never an AV notification.
    log("control.privateSentinelReturned", ["syntheticPrivateControl": true, "countsAsAVNotification": false])
  }

  private struct Reply: Sendable {
    let value: ProbeAudioValues
    let sessionDomain: String
    let ioDomain: String
  }
  private func call(_ operation: @escaping (@escaping ProbeAudioCompletion) -> Void) async -> Reply {
    await withCheckedContinuation { continuation in
      operation { value, sessionDomain, ioDomain in
        MainActor.assumeIsolated { continuation.resume(returning: Reply(value: value, sessionDomain: sessionDomain, ioDomain: ioDomain)) }
      }
    }
  }
  private func operationFields(_ reply: Reply) -> [String: Any] {
    let value = reply.value
    return ["sessionAttempted": value.sessionAttempted, "sessionSuccess": value.sessionSuccess,
      "sessionErrorDomain": reply.sessionDomain, "sessionErrorCode": value.sessionErrorCode,
      "ioSuccess": value.ioSuccess, "ioErrorDomain": reply.ioDomain, "ioErrorCode": value.ioErrorCode,
      "callMain": value.callMain, "callAudioQueue": value.callAudioQueue, "completionMain": value.completionMain,
      "engineRunning": value.engineRunning, "renderFrames": value.renderFrames, "renderCallbacks": value.renderCallbacks,
      "cleanupDeactivationRequested": value.cleanupDeactivationRequested]
  }

  func run(silentOutput: Bool) async {
    guard !hasRun, !running else { return }
    guard #available(iOS 27.0, *) else { status = "This measurement needs iOS 27 or later."; return }
    hasRun = true; running = true; runID = UUID().uuidString
    do {
      let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      let path = directory.appendingPathComponent("audio-lifecycle-\(runID).jsonl")
      guard FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        status = "Cannot reserve private trace."; running = false; return
      }
      file = try FileHandle(forWritingTo: path)
      let executable = try Data(contentsOf: Bundle.main.executableURL!)
      log("launch", ["classification": "proposed physical ordinary-session producer/decoder/Swift-consumer measurement",
        "simulator": {
          #if targetEnvironment(simulator)
          true
          #else
          false
          #endif
        }(), "osVersion": UIDevice.current.systemVersion, "silentOutputRequested": silentOutput,
        "executableSHA256": SHA256.hash(data: executable).map { String(format: "%02x", $0) }.joined()])
      installObservers()
      var previous = ProcessInfo.processInfo.systemUptime
      heartbeat = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(20))
          let now = ProcessInfo.processInfo.systemUptime
          self?.ticks += 1; self?.maxTickGapMS = max(self?.maxTickGapMS ?? 0, (now - previous) * 1000); previous = now
        }
      }
      let activeDeadline = Date().addingTimeInterval(10)
      while UIApplication.shared.applicationState != .active, Date() < activeDeadline { try await Task.sleep(for: .milliseconds(20)) }
      guard UIApplication.shared.applicationState == .active else { throw ProbeFailure.inactive }
      log("application.activeBeforeAudio", ["active": true])
      phase = "configure"
      try await SystemAudioSession.configureForConversation() // Actual SDK queue and configuration implementation.
      log("session.configured", ["actualSDKConfiguration": true])
      for (index, name) in ["sync-activate", "sync-deactivate", "async-activate", "async-deactivate"].enumerated() {
        guard UIApplication.shared.applicationState == .active else { throw ProbeFailure.inactive }
        phase = name; status = name
        log("operation.requested", ["index": index, "applicationActive": true])
        let result = await call { ProbeAudioRun(Int32(index), silentOutput, $0) }
        log("operation.result", operationFields(result))
        guard result.value.sessionAttempted, result.value.sessionSuccess, result.value.ioSuccess,
          result.sessionDomain.isEmpty, result.ioDomain.isEmpty, !result.value.callMain, result.value.callAudioQueue else { throw ProbeFailure.operation }
        let ticksBefore = ticks; let began = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(5))
        let observed = await call { ProbeAudioSnapshot($0) }
        var fields = operationFields(observed)
        fields["observationElapsedMS"] = (ProcessInfo.processInfo.systemUptime - began) * 1000
        fields["mainHeartbeatTicks"] = ticks - ticksBefore
        log("operation.observed", fields)
        if silentOutput {
          guard observed.value.engineRunning == (index % 2 == 0),
            index % 2 == 0 ? observed.value.renderFrames > result.value.renderFrames : observed.value.renderFrames == result.value.renderFrames
          else { throw ProbeFailure.render }
        }
      }
      phase = "cleanup"
      let cleanup = await call { ProbeAudioCleanup($0) }; log("fixture.cleanup", operationFields(cleanup))
      guard !cleanup.value.engineRunning, cleanup.sessionDomain.isEmpty,
        !cleanup.value.sessionAttempted || cleanup.value.sessionSuccess else { throw ProbeFailure.operation }
      log("experiment.completed", ["operations": 4, "maxMainHeartbeatGapMS": maxTickGapMS,
        "ordinarySessionOnly": true, "notLCKInterruptionAcceptance": true])
      status = "Completed. Retain the private trace and compare all three event inventories."
    } catch {
      phase = "cleanup"
      log("experiment.failed", ["errorType": String(describing: type(of: error))])
      let cleanup = await call { ProbeAudioCleanup($0) }; log("fixture.cleanup", operationFields(cleanup))
      status = "Failed. Retain the trace; stop this app before another attempt."
    }
    heartbeat?.cancel(); heartbeat = nil
    log("done")
    try? file?.close(); file = nil; running = false
  }
  private enum ProbeFailure: Error { case inactive, operation, render }
}

@main
private struct AudioLifecycleProbeApp: App {
  @StateObject private var model = AudioLifecycleProbe()
  @State private var silentOutput = false
  var body: some Scene {
    WindowGroup {
      VStack(spacing: 20) {
        Text("Audio lifecycle measurement").font(.headline)
        Toggle("Render silent output (no input capture)", isOn: $silentOutput)
        Text(model.status)
        Button("Run once") { Task { await model.run(silentOutput: silentOutput) } }
          .disabled(model.running || model.hasRun)
      }.padding()
        .task {
          // Fixture-only launch controls, requiring an explicit operator request.
          // No SDK compile flag or default launch behavior changes.
          if CommandLine.arguments.contains("--run-ordinary-audio-probe") {
            silentOutput = CommandLine.arguments.contains("--silent-output")
            await model.run(silentOutput: silentOutput)
          }
        }
    }
  }
}
