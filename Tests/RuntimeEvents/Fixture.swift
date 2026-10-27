#if targetEnvironment(simulator)
import SwiftUI
@preconcurrency import CallKit
import AVFAudio
@preconcurrency import PushKit

private final class ReportReceipt: @unchecked Sendable {
  private let lock = NSLock()
  private var replies = 0
  func nextReply() -> Int {
    lock.lock()
    defer { lock.unlock() }
    replies += 1
    return replies
  }
}

@MainActor
final class Fixture: NSObject, UIApplicationDelegate, @preconcurrency CXProviderDelegate, @preconcurrency PKPushRegistryDelegate {
  var provider: CXProvider!
  var background: UIBackgroundTaskIdentifier = .invalid
  let controller = CXCallController(queue: .main)
  var registry: PKPushRegistry!
  private let startedWallTimeMS = Int64(Date().timeIntervalSince1970 * 1000)
  private var phaseProbe: ForegroundPhaseProbe?
  private var phaseProbeTimer: Timer?
  func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    guard RuntimeBootstrap.activate() else { fatalError("Fixture runtime refused") }
    let config = CXProviderConfiguration()
    config.maximumCallGroups = 3
    config.maximumCallsPerCallGroup = 3
    provider = CXProvider(configuration: config)
    provider.setDelegate(self, queue: .main)
    registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    background = app.beginBackgroundTask(withName: "Inspector acceptance") {}
    if let runID = ProcessInfo.processInfo.environment["CKSIM_RUN_ID"] {
      phaseProbe = ForegroundPhaseProbe(nonce: runID, startedWallTimeMS: startedWallTimeMS)
      samplePhaseProbe()
      phaseProbeTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
        Task { @MainActor [weak self] in self?.samplePhaseProbe() }
      }
    }
    return true
  }
  private func samplePhaseProbe() {
    guard let phaseProbe,
          let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
          let data = try? Data(contentsOf: documents.appendingPathComponent(".callkit-simulator/session.json")),
          let session = try? JSONDecoder().decode(ForegroundPhaseSession.self, from: data),
          session.schemaVersion == 1, session.bundleID == Bundle.main.bundleIdentifier,
          session.pid == Int(ProcessInfo.processInfo.processIdentifier),
          session.runID == ProcessInfo.processInfo.environment["CKSIM_RUN_ID"] else { return }
    phaseProbe.sample(session: session)
  }
  func ring(uuid: UUID = UUID()) {
    let enteredAt = DispatchTime.now().uptimeNanoseconds
    let receipt = ReportReceipt()
    let handle = "+12025550123"
    let update = CXCallUpdate()
    update.localizedCallerName = "Alex Morgan"
    update.remoteHandle = CXHandle(type: .phoneNumber, value: handle)
    update.supportsHolding = true
    provider.reportNewIncomingCall(with: uuid, update: update) { error in
      let observed = error as NSError?
      CKSimEmit("fixture.reportCompleted", ["callUUID": uuid.uuidString, "handle": handle,
        "domain": observed?.domain ?? "", "code": observed?.code ?? 0,
        "replyCount": receipt.nextReply(), "main": Thread.isMainThread,
        "latencyMS": Double(DispatchTime.now().uptimeNanoseconds - enteredAt) / 1_000_000])
    }
  }
  func outgoing() {
    controller.request(CXTransaction(action: CXStartCallAction(call: UUID(), handle: CXHandle(type: .generic, value: "Taylor")))) { _ in }
  }
  func providerDidReset(_ provider: CXProvider) {}
  func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {}
  func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
    ring(uuid: (payload.dictionaryPayload["callUUID"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID())
    if payload.dictionaryPayload["operation"] as? String == "outgoing" { outgoing() }
    completion()
  }
  func provider(_ provider: CXProvider, execute transaction: CXTransaction) -> Bool {
    for action in transaction.actions {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
        if action is CXPlayDTMFCallAction { action.fail() } else { action.fulfill() }
        if let start = action as? CXStartCallAction {
          let update = CXCallUpdate()
          update.localizedCallerName = "Taylor Reed"
          provider.reportCall(with: start.callUUID, updated: update)
          provider.reportOutgoingCall(with: start.callUUID, startedConnectingAt: Date())
          provider.reportOutgoingCall(with: start.callUUID, connectedAt: Date())
        }
      }
    }
    return true
  }
}
@main
struct FixtureApp: App {
  @UIApplicationDelegateAdaptor(Fixture.self) var fixture
  var body: some Scene {
    WindowGroup {
      VStack(spacing: 20) {
        Image(systemName: "phone.connection.fill").font(.largeTitle)
        Text("Runtime event fixture").font(.title)
        Button("Incoming call") { fixture.ring() }
      }
    }
  }
}
#endif
