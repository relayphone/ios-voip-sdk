import AVFAudio
import CryptoKit
import SwiftUI

#if SDK_DEVICE_QA
private struct QAConversation: Encodable {
  let id: UUID
  let status: ConversationStatus
  let connected: Bool
  let pendingActionID: UUID?
  let pendingKind: ConversationActionKind?
  init(_ value: ConversationSnapshot) {
    id = value.id; status = value.status; connected = value.connectedAt != nil
    pendingActionID = value.pending?.id; pendingKind = value.pending?.kind
  }
}
private struct QAFrame: Encodable {
  let traceVersion = 1
  let event: String
  let nanoseconds: UInt64
  let wallTimeMS: Int64
  let runID: UUID
  let launchID: UUID
  let sequence: UInt64
  let pid: Int32
  let bundleID: String
  let scenario: SDKDeviceQAConfiguration.Scenario
  let osVersion: String
  let sourceCommit: String
  let sourceInputsSHA256: String
  let executableSHA256: String
  let appState: Int
  let mainThread: Bool
  let native: SDKDeviceQARecord?
  let conversations: [QAConversation]
  let conversationID: UUID?
  let actionID: UUID?
  let actionKind: ConversationActionKind?
  let tokenPresent: Bool?
  let clientEvent: ConversationEvent?
}

/// One native SDK owner. No fixture provider, manager or PushKit registry is constructed.
@MainActor
private final class SDKDeviceQAController: ObservableObject {
  static let shared = SDKDeviceQAController()
  @Published private(set) var status = "Starting SDK device QA"
  @Published private(set) var liveCount = 0
  private(set) var storage: SDKDeviceQAStorage?
  private var application: VoIPApplication?
  private var sequence: UInt64 = 0
  private var started = false
  private var traceFailed = false
  private var sourceCommit = "missing"
  private var sourceHash = "missing"
  private var executableHash = "missing"
  private var latest: [ConversationSnapshot] = []
  private var connected: Set<UUID> = []
  private var cleanup: [UUID: Task<Void, Never>] = [:]
  private var stateObserver: UUID?
  private var tokenObserver: UUID?
  private var eventObserver: UUID?

  func start() {
    guard !started else { return }
    started = true
    let entryTime = VSDeviceQANanoseconds()
    do {
      let environment = ProcessInfo.processInfo.environment
      var override: SDKDeviceQAConfiguration?
      if environment["SDK_DEVICE_QA_RUN_ID"] != nil || environment["SDK_DEVICE_QA_SCENARIO"] != nil {
        guard let value = environment["SDK_DEVICE_QA_RUN_ID"], let id = UUID(uuidString: value),
              let raw = environment["SDK_DEVICE_QA_SCENARIO"],
              let scenario = SDKDeviceQAConfiguration.Scenario(rawValue: raw) else {
          throw ConversationClientError.invalidConfiguration
        }
        override = .init(runID: id, scenario: scenario)
      }
      guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
        throw ConversationClientError.invalidConfiguration
      }
      storage = try SDKDeviceQAStorage(documentsURL: documents, configurationOverride: override)
      sourceCommit = Bundle.main.object(forInfoDictionaryKey: "SDKDeviceQASourceCommit") as? String ?? "missing"
      sourceHash = Bundle.main.object(forInfoDictionaryKey: "SDKDeviceQASourceInputsSHA256") as? String ?? "missing"
      if let executable = Bundle.main.executableURL {
        executableHash = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
      }
      record("app.entry", nanoseconds: entryTime)
      SDKDeviceQADiagnostics.install { [weak self] value in
        self?.record(value.event.rawValue, nanoseconds: value.nanoseconds, native: value)
      }
      record("launch.registrationBeginning")
      let application = try VoIPApplication.start(configuration: .init(
        client: .init(includesConversationInRecents: false), simulatorSupport: false))
      self.application = application
      let client = application.client
      tokenObserver = application.pushService.observeToken { [weak self] state in
        guard let self else { return }
        do { try self.storage?.writeToken(state.token?.value) }
        catch { self.traceFailure() }
        self.record("token.state", tokenPresent: state.token != nil)
      }
      stateObserver = client.observeState { [weak self] state in self?.stateChanged(state) }
      eventObserver = client.observeEvents { [weak self] event in self?.record("client.event", clientEvent: event) }
      client.setConversationHandler(.init(
        join: { [weak self] conversation, context in
          self?.record("handler.enter", conversationID: conversation.id, actionID: context.actionID, actionKind: .join)
          try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat)
          self?.record("handler.returning", conversationID: conversation.id, actionID: context.actionID, actionKind: .join)
        },
        start: { [weak self] conversation, context in
          self?.record("handler.enter", conversationID: conversation.id, actionID: context.actionID, actionKind: .start)
          try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat)
          self?.record("handler.returning", conversationID: conversation.id, actionID: context.actionID, actionKind: .start)
        },
        end: { [weak self] conversation, context in
          self?.record("handler.enter", conversationID: conversation.id, actionID: context.actionID, actionKind: .end)
          self?.record("handler.returning", conversationID: conversation.id, actionID: context.actionID, actionKind: .end)
        }))
      record("launch.ready")
      status = traceFailed ? "Trace unavailable" : "SDK ready — " + (storage?.configuration.scenario.rawValue ?? "unknown")
      if storage?.configuration.scenario == .activeCall,
         environment["SDK_DEVICE_QA_AUTO_REFERENCE"] == "1" {
        record("fixture.automaticReferenceRequested")
        startReferenceCall()
      }
    } catch { status = "SDK device QA could not start" }
  }

  private func stateChanged(_ state: ConversationStateUpdate) {
    latest = state.conversations
    liveCount = latest.filter { $0.status != .ended }.count
    record("client.snapshot")
    guard let client = application?.client else { return }
    for conversation in latest where conversation.status == .connected && connected.insert(conversation.id).inserted {
      do {
        try client.reportConversation(conversation.id, report: .connected)
        record("fixture.connectedReport", conversationID: conversation.id)
      } catch { record("fixture.connectedReportFailed", conversationID: conversation.id) }
    }
    // Proposed fixture budget from first live observation, not an OS deadline.
    for conversation in latest where conversation.status != .ended && cleanup[conversation.id] == nil {
      let id = conversation.id
      record("fixture.cleanupScheduled", conversationID: id)
      cleanup[id] = Task { @MainActor [weak self] in
        do { try await Task.sleep(for: .seconds(60)) } catch { return }
        guard let self, self.latest.contains(where: { $0.id == id && $0.status != .ended }) else { return }
        self.record("fixture.cleanupDeadline", conversationID: id)
        do { try await client.endConversation(id) }
        catch { self.record("fixture.endFailed", conversationID: id) }
      }
    }
    let live = Set(latest.filter { $0.status != .ended }.map(\.id))
    for (id, task) in cleanup where !live.contains(id) { task.cancel(); cleanup.removeValue(forKey: id) }
  }

  func startReferenceCall() {
    guard let client = application?.client else { return }
    Task { @MainActor [weak self] in
      do {
        let id = try await client.startConversation(to: .init(id: "qa-reference", displayName: "SDK QA reference"))
        self?.record("fixture.startRequested", conversationID: id)
      } catch { self?.record("fixture.startFailed") }
    }
  }
  func endAll() {
    guard let client = application?.client else { return }
    let ids = latest.filter { $0.status != .ended }.map(\.id)
    Task { @MainActor [weak self] in
      for id in ids {
        do { try await client.endConversation(id) }
        catch { self?.record("fixture.endFailed", conversationID: id) }
      }
    }
  }
  private func traceFailure() { traceFailed = true; status = "Trace unavailable" }

  private func record(_ event: String, nanoseconds: UInt64 = VSDeviceQANanoseconds(),
                      native: SDKDeviceQARecord? = nil, conversationID: UUID? = nil,
                      actionID: UUID? = nil, actionKind: ConversationActionKind? = nil,
                      tokenPresent: Bool? = nil, clientEvent: ConversationEvent? = nil) {
    guard let storage else { return }
    sequence &+= 1
    let frame = QAFrame(event: event, nanoseconds: nanoseconds,
      wallTimeMS: Int64(Date().timeIntervalSince1970 * 1_000), runID: storage.configuration.runID,
      launchID: storage.launchID, sequence: sequence, pid: getpid(),
      bundleID: Bundle.main.bundleIdentifier ?? "missing", scenario: storage.configuration.scenario,
      osVersion: ProcessInfo.processInfo.operatingSystemVersionString, sourceCommit: sourceCommit,
      sourceInputsSHA256: sourceHash, executableSHA256: executableHash,
      appState: UIApplication.shared.applicationState.rawValue, mainThread: Thread.isMainThread,
      native: native, conversations: latest.map(QAConversation.init), conversationID: conversationID,
      actionID: actionID, actionKind: actionKind, tokenPresent: tokenPresent, clientEvent: clientEvent)
    do { try storage.append(recordData: JSONEncoder().encode(frame)) }
    catch { traceFailure() }
  }
}

@MainActor
private final class SDKDeviceQALaunchDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    SDKDeviceQAController.shared.start()
    return true
  }
}

@main
private struct SDKDeviceProbeApp: App {
  @UIApplicationDelegateAdaptor(SDKDeviceQALaunchDelegate.self) private var delegate
  @StateObject private var controller = SDKDeviceQAController.shared
  var body: some Scene {
    WindowGroup {
      VStack(spacing: 20) {
        Text(controller.status)
        Text("Live conversations: \(controller.liveCount)")
        Button("Start reference call") { controller.startReferenceCall() }
        Button("End all conversations") { controller.endAll() }
        Text("Native action timing is separate from the operator's screen gesture.")
          .font(.footnote)
      }.padding()
    }
  }
}
#endif
