import AVFoundation
import ExpoModulesCore
import IosVoipSDK
#if targetEnvironment(simulator) && canImport(livekit_react_native_webrtc)
@preconcurrency import livekit_react_native_webrtc
#endif

#if targetEnvironment(simulator) && canImport(livekit_react_native_webrtc)
private struct MediaEngineSample: Sendable {
  let deviceID: String
  let inputAvailable: Bool
  let outputAvailable: Bool
  let isEngineRunning: Bool
  let category: String
  let mode: String
}
#endif

private enum JourneyConfiguration {
  static let environment = ProcessInfo.processInfo.environment
  static let runID = environment["SDK_M2_RUN_ID"] ?? environment["SDK_M1_RUN_ID"] ?? environment["SDK_M0_RUN_ID"] ?? UUID().uuidString
  static let m0 = environment["SDK_M0_ACCEPTANCE"] == "1"
  static let m1Case = environment["SDK_M1_CASE"] ?? ""
  static let m2Case = environment["SDK_M2_CASE"] ?? ""
}

/// Example-only instrumentation. Never records push tokens or arbitrary payloads.
@MainActor
private enum JourneyTrace {
  static let epoch = DispatchTime.now().uptimeNanoseconds
  static let environment = JourneyConfiguration.environment
  static let runID = JourneyConfiguration.runID
  static let m0 = JourneyConfiguration.m0
  static let m1Case = JourneyConfiguration.m1Case
  static let m2Case = JourneyConfiguration.m2Case
  static var sequence = 0

  static func record(_ event: String, _ fields: [String: Any] = [:], observedAt: Date = Date()) {
    let start = epoch
    sequence += 1
    var row = fields
    row.merge([
      "event": event, "sequence": sequence, "runID": runID,
      "pid": Int(getpid()), "bundleID": Bundle.main.bundleIdentifier ?? "unknown",
      "simulatorID": environment["SIMULATOR_UDID"] ?? "device",
      "t_ms": (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000,
      "wallTimeMS": Int64(observedAt.timeIntervalSince1970 * 1000),
      "main": Thread.isMainThread
    ]) { _, value in value }
    guard let bytes = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
    ProbeTraceWriter.emit(bytes)
  }

  private static let formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  static func iso(_ date: Date) -> String { formatter.string(from: date) }
}

public final class VoIPExampleAppDelegateSubscriber: ExpoAppDelegateSubscriber {
  public func appDelegateWillBeginInitialization() {
    JourneyTrace.record("app.entry")
    JourneyTrace.record("launch", ["traceVersion": 2,
      "mode": !JourneyTrace.m2Case.isEmpty ? "sdk-m2" : JourneyTrace.m0 ? "sdk-m0" : "sdk-m1",
      "case": JourneyTrace.m2Case.isEmpty ? JourneyTrace.m1Case : JourneyTrace.m2Case])
    if ["cold-launch", "unhandled-expiry"].contains(JourneyTrace.m1Case) {
      ExampleJourney.shared.startColdLaunch()
    }
  }
}

@MainActor
private final class ExampleJourney {
  static let shared = ExampleJourney()
  private var client: ConversationClient?
  private var stateObserver: UUID?
  private var mediaObserver: UUID?
  private var mediaEventCounts: [String: Int] = [:]
  private var previousStates: [UUID: ConversationStatus] = [:]
  private var coldTask: Task<[String: String], Error>?
  private var coldJoinTask: Task<Void, Never>?
  private var completed = false

  private init() {}

  private func bindClient() throws -> ConversationClient {
    if let client { return client }
    let application = try ExpoMediaSupport.startFromBundle()
    let active = SimulatorSupport.activateIfNeeded()
    JourneyTrace.record("sdk.activation", ["active": active])
    let client = application.client
    self.client = client
    // Legacy M0 marker: bind the SDK-owned manager through its public client.
    // No manager/provider is constructed by this example.
    JourneyTrace.record("sdk.managerCreated", ["owner": "ConversationClient.shared"])
    stateObserver = client.observeState { [weak self] update in self?.recordState(update) }
    if !JourneyTrace.m2Case.isEmpty {
      mediaObserver = client.observeEvents { [weak self] event in
        guard let self, !self.completed else { return }
        switch event.type {
        case .audioActivated, .audioDeactivated, .audioActivationMissing, .audioActivationFailed:
          let name = event.type.rawValue
          self.mediaEventCounts[name, default: 0] += 1
          var values: [String: Any] = ["name": name, "count": self.mediaEventCounts[name]!]
          if let id = event.conversationID { values["conversationID"] = id.uuidString }
          JourneyTrace.record("m2.audioEvent", values)
        default: break
        }
      }
    }
    return client
  }

  private func recordState(_ update: ConversationStateUpdate) {
    guard !completed else { return }
    let snapshots = update.conversations.map { conversation -> [String: Any] in
      var row: [String: Any] = ["id": conversation.id.uuidString,
        "status": conversation.status.rawValue, "direction": conversation.direction.rawValue,
        "isMuted": conversation.isMuted, "isVideo": conversation.isVideo,
        "hasConnectedAt": conversation.connectedAt != nil]
      if let pending = conversation.pending {
        row["pending"] = ["id": pending.id.uuidString, "kind": pending.kind.rawValue,
          "deadline": JourneyTrace.iso(pending.deadline), "origin": pending.origin.rawValue]
      }
      return row
    }
    JourneyTrace.record("sdk.snapshot", ["revision": update.revision, "conversations": snapshots])
    for conversation in update.conversations where previousStates[conversation.id] != conversation.status {
      let legacy: String
      switch conversation.status {
      case .ringing, .dialing: legacy = "idle"
      case .connecting: legacy = "joining"
      case .connected: legacy = "joined"
      case .held: legacy = "paused"
      case .ending: legacy = "leaving"
      case .ended: legacy = "left"
      }
      JourneyTrace.record("sdk.state", ["conversationID": conversation.id.uuidString,
        "state": legacy, "status": conversation.status.rawValue, "source": "clientProjection"])
      previousStates[conversation.id] = conversation.status
    }
    let live = Set(update.conversations.map(\.id))
    previousStates = previousStates.filter { live.contains($0.key) }
  }

  private func fixturePayload() -> IncomingCallPayload {
    IncomingCallPayload(eventId: "sdk-example-event-" + JourneyTrace.runID,
      serverCallId: "sdk-example-server-" + JourneyTrace.runID,
      caller: .init(id: "sdk-example-caller", displayName: "SDK example", phoneNumber: "+15555550142"),
      hasVideo: false)
  }

  func acceptance() async throws {
    guard JourneyTrace.m0 else { throw JourneyError.wrongMode }
    do {
      let client = try bindClient()
      guard client.snapshots.isEmpty else { throw JourneyError.alreadyCalling }
      client.setConversationHandler(.init(join: { conversation, _ in
        JourneyTrace.record("sdk.action", ["kind": "JoinConversationAction", "conversationID": conversation.id.uuidString])
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat)
      }, start: { _, _ in throw JourneyError.wrongMode }, end: { conversation, _ in
        JourneyTrace.record("sdk.action", ["kind": "EndConversationAction", "conversationID": conversation.id.uuidString])
      }))
      let id = try await client.reportIncomingConversation(fixturePayload())
      JourneyTrace.record("sdk.incomingReported", ["conversationID": id.uuidString])
      // Acceptance interval only; the SDK still uses the platform action deadline.
      try await Task.sleep(for: .seconds(1))
      guard client.snapshots.first(where: { $0.id == id })?.status == .ringing else { throw JourneyError.notRinging }
      JourneyTrace.record("sdk.ringing", ["conversationID": id.uuidString])
      try await client.joinConversation(id)
      try await waitUntil { client.snapshots.first(where: { $0.id == id })?.status == .connected }
      JourneyTrace.record("sdk.joined", ["conversationID": id.uuidString])
      try await client.endConversation(id)
      try await waitUntil { client.snapshots.isEmpty }
      JourneyTrace.record("sdk.ended", ["conversationID": id.uuidString])
      finish(success: true)
    } catch {
      finish(success: false, errorType: String(reflecting: type(of: error)))
      throw error
    }
  }

  func simulatePush(_ payloadJSON: String, mustReport: Bool, label: String) throws -> String {
    guard ["primary", "cold"].contains(label) else { throw JourneyError.invalidTrace }
    _ = try bindClient()
    #if targetEnvironment(simulator)
    guard let data = payloadJSON.data(using: .utf8),
          let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw JourneyError.invalidPayload
    }
    let pushID = UUID().uuidString
    JourneyTrace.record(JourneyTrace.m2Case.isEmpty ? "m1.pushInjected" : "m2.pushInjected", ["pushID": pushID, "mustReport": mustReport, "label": label])
    CKSimInjectPush(payload, mustReport, pushID)
    return pushID
    #else
    throw JourneyError.simulatorOnly
    #endif
  }

  func startColdLaunch() {
    guard coldTask == nil else { return }
    coldTask = Task { @MainActor in
      let client = try bindClient()
      let bytes = try JSONEncoder().encode(["incomingCall": fixturePayload()])
      guard let json = String(data: bytes, encoding: .utf8) else { throw JourneyError.invalidPayload }
      _ = try simulatePush(json, mustReport: true, label: "cold")
      try await waitUntil { client.snapshots.contains { $0.status == .ringing } }
      guard let conversation = client.snapshots.first else { throw JourneyError.noIncomingConversation }
      let id = conversation.id
      JourneyTrace.record("m1.coldJoinRequested", ["conversationID": id.uuidString])
      coldJoinTask = Task { @MainActor in
        do {
          try await client.joinConversation(id)
          if !completed {
            JourneyTrace.record("m1.coldJoinRequestResult", ["conversationID": id.uuidString, "accepted": true])
          }
        } catch {
          if !completed {
            JourneyTrace.record("m1.coldJoinRequestResult", ["conversationID": id.uuidString, "accepted": false,
              "errorType": String(reflecting: type(of: error))])
          }
        }
      }
      try await waitUntil { client.snapshots.first(where: { $0.id == id })?.pending?.kind == .join }
      guard let pending = client.snapshots.first(where: { $0.id == id })?.pending else { throw JourneyError.noPendingAction }
      let clockBefore = Date()
      #if targetEnvironment(simulator)
      CKSimEmit("m1.coldPendingClock", ["conversationID": id.uuidString, "actionID": pending.id.uuidString])
      #endif
      let observedAt = Date()
      JourneyTrace.record("m1.coldPending", ["conversationID": id.uuidString, "actionID": pending.id.uuidString,
        "deadline": JourneyTrace.iso(pending.deadline), "remainingMS": pending.deadline.timeIntervalSince(observedAt) * 1000,
        "handlerAttached": false, "clockBeforeMS": Int64(clockBefore.timeIntervalSince1970 * 1000)], observedAt: observedAt)
      return ["conversationID": id.uuidString, "actionID": pending.id.uuidString,
        "deadline": JourneyTrace.iso(pending.deadline)]
    }
  }

  func waitForColdStart() async throws -> [String: String] {
    guard let coldTask else { throw JourneyError.wrongMode }
    return try await coldTask.value
  }

  #if targetEnvironment(simulator)
  /// A sandbox-local runner receipt gates the first push. This only observes
  /// control completion; it never changes runtime faults or audio authorization.
  func awaitMediaControl() async throws {
    let runID = JourneyTrace.runID
    let mode = JourneyTrace.m2Case
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
    guard ["livekit", "stale-audio"].contains(mode), !runID.isEmpty, runID.count <= 128,
          runID.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { throw JourneyError.wrongMode }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-m2-control-" + runID + ".json")
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while ContinuousClock.now < deadline {
      if FileManager.default.fileExists(atPath: url.path) {
        let bytes = try Data(contentsOf: url)
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(value.keys) == ["runID", "case", "pid", "staleAudio"],
              value["runID"] as? String == runID, value["case"] as? String == mode,
              let pid = value["pid"] as? NSNumber, CFGetTypeID(pid) != CFBooleanGetTypeID(),
              pid.doubleValue == Double(getpid()),
              let stale = value["staleAudio"] as? NSNumber, CFGetTypeID(stale) == CFBooleanGetTypeID(),
              stale.boolValue == (mode == "stale-audio") else { throw JourneyError.invalidMediaControl }
        try FileManager.default.removeItem(at: url)
        JourneyTrace.record("m2.controlReady", ["staleAudio": stale.boolValue])
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw JourneyError.mediaControlDeadline
  }
  #endif

  #if targetEnvironment(simulator) && canImport(livekit_react_native_webrtc)
  /// Public getters on the shared audio executor. No factory/session
  /// activation, availability writes, or private runtime lookup is performed.
  func mediaSnapshot(_ module: WebRTCModule, label: String) async throws -> String {
    let labels: Set<String> = ["poll", "initial", "demand", "active", "speaker", "held", "resumed", "ended", "failed"]
    guard !JourneyTrace.m2Case.isEmpty, !completed, labels.contains(label) else { throw JourneyError.wrongMode }
    let client = try bindClient()
    let moduleID = String(describing: ObjectIdentifier(module))
    let sample = try await withCheckedThrowingContinuation { (reply: CheckedContinuation<MediaEngineSample, Error>) in
      VSAudioSessionGetQueue().async {
        guard let device = module.audioDeviceModule else { reply.resume(throwing: JourneyError.mediaUnavailable); return }
        let availability = device.engineAvailability
        let session = AVAudioSession.sharedInstance()
        reply.resume(returning: MediaEngineSample(deviceID: String(describing: ObjectIdentifier(device)),
          inputAvailable: availability.isInputAvailable.boolValue, outputAvailable: availability.isOutputAvailable.boolValue,
          isEngineRunning: device.isEngineRunning, category: session.category.rawValue, mode: session.mode.rawValue))
      }
    }
    let routes = client.audioRoutes
    let snapshot: [String: Any] = ["label": label, "moduleID": moduleID, "deviceID": sample.deviceID,
      "inputAvailable": sample.inputAvailable, "outputAvailable": sample.outputAvailable,
      "isEngineRunning": sample.isEngineRunning, "routeCount": routes.routes.count,
      "currentRouteType": (routes.current?.type as Any?) ?? NSNull(), "category": sample.category, "mode": sample.mode,
      "activatedCount": mediaEventCounts[ConversationEvent.audioActivated.rawValue, default: 0],
      "deactivatedCount": mediaEventCounts[ConversationEvent.audioDeactivated.rawValue, default: 0],
      "missingCount": mediaEventCounts[ConversationEvent.audioActivationMissing.rawValue, default: 0],
      "failedCount": mediaEventCounts[ConversationEvent.audioActivationFailed.rawValue, default: 0]]
    if label != "poll" { JourneyTrace.record("m2.mediaSnapshot", snapshot) }
    let bytes = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
    guard let json = String(data: bytes, encoding: .utf8) else { throw JourneyError.mediaUnavailable }
    return json
  }
  #endif

  /// Whitelisted test fields prevent accidental payload/token logging.
  func trace(_ event: String, fieldsJSON: String) throws {
    guard !completed else { return }
    let events: Set<String> = ["m1.jsReady", "m1.subscriptionsStarting", "m1.handlerAttached", "m1.handler", "m1.cancelled",
      "m1.assertion", "m1.hookConversations", "m1.hookToken", "m1.event", "m1.expiryObserved"]
    let mediaEvents: Set<String> = ["m2.assertion", "m2.handler", "m2.localTrack", "m2.localTrackReleased", "m2.recordingDemand", "m2.hookEvent"]
    let fields: Set<String> = ["enabled", "accepted", "label", "passed", "conversationID", "kind", "origin", "deadline",
      "held", "muted", "attached", "available", "tokenType", "name", "count", "status",
      "pending", "hasConnectedAt", "reason"]
    guard (events.contains(event) || (!JourneyTrace.m2Case.isEmpty && mediaEvents.contains(event))), let bytes = fieldsJSON.data(using: .utf8),
          let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          Set(value.keys).isSubset(of: fields),
          value.values.allSatisfy({ $0 is String || $0 is NSNumber || $0 is NSNull }) else {
      throw JourneyError.invalidTrace
    }
    if event == "m2.hookEvent" {
      let names: Set<String> = ["audioActivated", "audioDeactivated", "audioActivationMissing", "audioActivationFailed",
        "providerReset", "providerOwnershipLost", "pushTokenUpdated"]
      guard Set(value.keys) == ["name"], let name = value["name"] as? String, names.contains(name) else {
        throw JourneyError.invalidTrace
      }
    }
    JourneyTrace.record(event, value)
  }

  func finish(success: Bool, errorType: String? = nil) {
    guard !completed else { return }
    completed = true
    var fields: [String: Any] = ["success": success]
    if let errorType { fields["errorType"] = errorType }
    JourneyTrace.record(JourneyTrace.m2Case.isEmpty ? "sdk.result" : "m2.result", fields)
    JourneyTrace.record("done")
  }

  private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !predicate() {
      guard ContinuousClock.now < deadline else { throw JourneyError.stateDeadline }
      try await Task.sleep(for: .milliseconds(25))
    }
  }
}

private enum JourneyError: Error {
  case alreadyCalling, noIncomingConversation, noPendingAction, notRinging, stateDeadline
  case wrongMode, simulatorOnly, invalidPayload, invalidTrace, mediaUnavailable, invalidMediaControl, mediaControlDeadline
}

/// Excluded from the distributed SDK. Synthetic push injection is simulator-only.
public final class VoIPExampleJourneyModule: Module {
  public func definition() -> ModuleDefinition {
    Name("VoIPExampleJourney")
    Constants(["acceptanceEnabled": JourneyConfiguration.m0, "m1Case": JourneyConfiguration.m1Case, "m2Case": JourneyConfiguration.m2Case,
      "runID": JourneyConfiguration.runID])
    AsyncFunction("acceptance") { (promise: Promise) in
      Task { @MainActor in
        do { try await ExampleJourney.shared.acceptance(); promise.resolve() }
        catch { promise.reject("journey", String(reflecting: type(of: error))) }
      }
    }
    AsyncFunction("simulatePush") { (payloadJSON: String, mustReport: Bool, label: String, promise: Promise) in
      Task { @MainActor in
        do { promise.resolve(try ExampleJourney.shared.simulatePush(payloadJSON, mustReport: mustReport, label: label)) }
        catch { promise.reject("journey", String(reflecting: type(of: error))) }
      }
    }
    AsyncFunction("waitForColdStart") { (promise: Promise) in
      Task { @MainActor in
        do { promise.resolve(try await ExampleJourney.shared.waitForColdStart()) }
        catch { promise.reject("journey", String(reflecting: type(of: error))) }
      }
    }
    #if targetEnvironment(simulator)
    AsyncFunction("awaitMediaControl") { (promise: Promise) in
      Task { @MainActor in
        do { try await ExampleJourney.shared.awaitMediaControl(); promise.resolve() }
        catch { promise.reject("journey", String(reflecting: type(of: error))) }
      }
    }
    AsyncFunction("mediaSnapshot") { (label: String, promise: Promise) in
      let context = self.appContext
      Task { @MainActor in
        do {
          #if canImport(livekit_react_native_webrtc)
          guard let context, let module: WebRTCModule = context.nativeModule(named: "WebRTCModule") else {
            throw JourneyError.mediaUnavailable
          }
          promise.resolve(try await ExampleJourney.shared.mediaSnapshot(module, label: label))
          #else
          throw JourneyError.mediaUnavailable
          #endif
        } catch { promise.reject("journey", String(reflecting: type(of: error))) }
      }
    }
    #endif
    AsyncFunction("trace") { (event: String, fieldsJSON: String, promise: Promise) in
      Task { @MainActor in
        do { try ExampleJourney.shared.trace(event, fieldsJSON: fieldsJSON); promise.resolve() }
        catch { promise.reject("journey", String(reflecting: type(of: error))) }
      }
    }
    AsyncFunction("finish") { (success: Bool, promise: Promise) in
      Task { @MainActor in ExampleJourney.shared.finish(success: success); promise.resolve() }
    }
  }
}
