import AVFoundation
import ExpoModulesCore
import IosVoipSDK
// LCK lacks concurrency annotations; keep this compatibility boundary in the example.
@preconcurrency import LiveCommunicationKit

/// Example-only instrumentation. It carries no push credentials or payloads.
@MainActor
private enum JourneyTrace {
  static let epoch = DispatchTime.now().uptimeNanoseconds
  static let runID = ProcessInfo.processInfo.environment["SDK_M0_RUN_ID"] ?? UUID().uuidString
  static var sequence = 0

  static func record(_ event: String, _ fields: [String: Any] = [:]) {
    let start = epoch
    sequence += 1
    var row = fields
    row.merge([
      "event": event, "sequence": sequence, "runID": runID,
      "pid": Int(getpid()), "bundleID": Bundle.main.bundleIdentifier ?? "unknown",
      "t_ms": (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000,
      "main": Thread.isMainThread
    ]) { _, value in value }
    guard let bytes = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
          let text = String(data: bytes, encoding: .utf8) else { return }
    print("PROBE " + text)
    fflush(nil)
  }
}

public final class VoIPExampleAppDelegateSubscriber: ExpoAppDelegateSubscriber {
  public func appDelegateWillBeginInitialization() {
    JourneyTrace.record("app.entry")
    JourneyTrace.record("launch", [
      "traceVersion": 2,
      "simulatorID": ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "device",
      "mode": "sdk-m0"
    ])
  }
}

@MainActor
private final class ExampleJourney: NSObject, @preconcurrency ConversationManagerDelegate {
  static let shared = ExampleJourney()
  private let manager: ConversationManager
  private var incomingID: UUID?

  private override init() {
    let active = SimulatorSupport.activateIfNeeded()
    JourneyTrace.record("sdk.activation", ["active": active])
    manager = ConversationManager(configuration: .init(
      ringtoneName: nil, iconTemplateImageData: nil,
      maximumConversationGroups: 1, maximumConversationsPerConversationGroup: 1,
      includesConversationInRecents: false, supportsVideo: false,
      supportedHandleTypes: [.phoneNumber]))
    super.init()
    manager.delegate = self
    JourneyTrace.record("sdk.managerCreated")
  }

  func ring() async throws -> String {
    guard manager.conversations.isEmpty else { throw JourneyError.alreadyCalling }
    let id = UUID()
    try await manager.reportNewIncomingConversation(uuid: id, update: .init(
      members: [Handle(type: .phoneNumber, value: "+15555550142", displayName: "SDK example")],
      capabilities: [.pausing]))
    incomingID = id
    JourneyTrace.record("sdk.incomingReported", ["conversationID": id.uuidString])
    return id.uuidString
  }

  func join() async throws {
    guard let id = incomingID else { throw JourneyError.noIncomingConversation }
    try await manager.perform([JoinConversationAction(conversationUUID: id)])
    try await waitForState(.joined, id: id)
    JourneyTrace.record("sdk.joined", ["conversationID": id.uuidString])
  }

  func end() async throws {
    guard let id = incomingID else { return }
    try await manager.perform([EndConversationAction(conversationUUID: id)])
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !manager.conversations.isEmpty {
      guard ContinuousClock.now < deadline else { throw JourneyError.stateDeadline }
      try await Task.sleep(for: .milliseconds(25))
    }
    incomingID = nil
    JourneyTrace.record("sdk.ended", ["conversationID": id.uuidString])
  }

  func acceptance() async throws {
    do {
      let id = try await ring()
      // Proposed acceptance interval: comfortably beyond the measured genuine
      // simulator teardown (~100 ms), without changing a platform deadline.
      try await Task.sleep(for: .seconds(1))
      guard let conversation = manager.conversations.first(where: { $0.uuid.uuidString == id }),
            conversation.state == .idle else { throw JourneyError.notRinging }
      JourneyTrace.record("sdk.ringing", ["conversationID": id])
      try await join()
      try await end()
      JourneyTrace.record("sdk.result", ["success": true])
      JourneyTrace.record("done")
    } catch {
      JourneyTrace.record("sdk.result", ["success": false, "error": String(describing: error)])
      JourneyTrace.record("done")
      throw error
    }
  }

  private func waitForState(_ state: Conversation.State, id: UUID) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while manager.conversations.first(where: { $0.uuid == id })?.state != state {
      guard ContinuousClock.now < deadline else { throw JourneyError.stateDeadline }
      try await Task.sleep(for: .milliseconds(25))
    }
  }

  func conversationManager(_ manager: ConversationManager, perform action: ConversationAction) {
    JourneyTrace.record("sdk.action", ["kind": String(describing: type(of: action)),
      "conversationID": action.conversationUUID.uuidString])
    if action is JoinConversationAction {
      try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat)
    }
    action.fulfill()
  }
  func conversationManager(_ manager: ConversationManager, conversationChanged conversation: Conversation) {
    JourneyTrace.record("sdk.state", ["conversationID": conversation.uuid.uuidString,
      "state": String(describing: conversation.state)])
  }
  func conversationManagerDidBegin(_ manager: ConversationManager) {}
  func conversationManagerDidReset(_ manager: ConversationManager) {}
  func conversationManager(_ manager: ConversationManager, timedOutPerforming action: ConversationAction) {
    JourneyTrace.record("sdk.timeout", ["kind": String(describing: type(of: action))])
  }
  func conversationManager(_ manager: ConversationManager, didActivate audioSession: AVAudioSession) {}
  func conversationManager(_ manager: ConversationManager, didDeactivate audioSession: AVAudioSession) {}
}

private enum JourneyError: Error {
  case alreadyCalling, noIncomingConversation, notRinging, stateDeadline
}

/// This module belongs to the example app, not the distributed SDK.
public final class VoIPExampleJourneyModule: Module {
  public func definition() -> ModuleDefinition {
    Name("VoIPExampleJourney")
    Constants(["acceptanceEnabled": ProcessInfo.processInfo.environment["SDK_M0_ACCEPTANCE"] == "1"])
    AsyncFunction("ring") { (promise: Promise) in
      Task { @MainActor in
        do { promise.resolve(try await ExampleJourney.shared.ring()) }
        catch { promise.reject("journey", String(describing: error)) }
      }
    }
    AsyncFunction("join") { (promise: Promise) in
      Task { @MainActor in
        do { try await ExampleJourney.shared.join(); promise.resolve() }
        catch { promise.reject("journey", String(describing: error)) }
      }
    }
    AsyncFunction("end") { (promise: Promise) in
      Task { @MainActor in
        do { try await ExampleJourney.shared.end(); promise.resolve() }
        catch { promise.reject("journey", String(describing: error)) }
      }
    }
    AsyncFunction("acceptance") { (promise: Promise) in
      Task { @MainActor in
        do { try await ExampleJourney.shared.acceptance(); promise.resolve() }
        catch { promise.reject("journey", String(describing: error)) }
      }
    }
  }
}
