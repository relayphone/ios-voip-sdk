// An app that uses CallKit and PushKit directly and doesn't link the runtime. The runtime smoke
// test launches it with the packaged runtime injected and drives a call with `cksim`.
#if targetEnvironment(simulator)
  @preconcurrency import CallKit
  @preconcurrency import PushKit
  import SwiftUI

  @available(iOS 26.4, *)
  @MainActor
  final class MetadataPushDelegate: NSObject, @preconcurrency PKPushRegistryDelegate {
    weak var app: SmokeDelegate?
    init(app: SmokeDelegate) { self.app = app }
    func pushRegistry(
      _ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials,
      for type: PKPushType
    ) {}
    func pushRegistry(
      _ registry: PKPushRegistry, didReceiveIncomingVoIPPushWith payload: PKPushPayload,
      metadata: PKVoIPPushMetadata, withCompletionHandler completion: @escaping () -> Void
    ) {
      app?.receive(payload)
      completion()
    }
  }

  @MainActor
  final class SmokeDelegate: NSObject, UIApplicationDelegate, @preconcurrency CXProviderDelegate,
    @preconcurrency PKPushRegistryDelegate
  {
    private var provider: CXProvider?
    private var registry: PKPushRegistry?
    private var metadataDelegate: (any PKPushRegistryDelegate)?

    func application(
      _ application: UIApplication,
      didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
      let provider = CXProvider(configuration: CXProviderConfiguration())
      provider.setDelegate(self, queue: .main)
      self.provider = provider
      let registry = PKPushRegistry(queue: .main)
      if #available(iOS 26.4, *),
        ProcessInfo.processInfo.environment["CKSIM_SMOKE_METADATA"] == "1"
      {
        let delegate = MetadataPushDelegate(app: self)
        metadataDelegate = delegate
        registry.delegate = delegate
      } else {
        registry.delegate = self
      }
      registry.desiredPushTypes = [.voIP]
      self.registry = registry
      return true
    }

    func providerDidReset(_ provider: CXProvider) {}

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) { action.fulfill() }
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) { action.fulfill() }

    func pushRegistry(
      _ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials,
      for type: PKPushType
    ) {}

    func pushRegistry(
      _ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
      for type: PKPushType, completion: @escaping () -> Void
    ) {
      receive(payload)
      completion()
    }

    func receive(_ payload: PKPushPayload) {
      let fields = payload.dictionaryPayload
      guard fields["report"] as? String != "skip" else { return }
      let uuid = (fields["callUUID"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
      let delay = fields["delayMS"] as? Int ?? 0
      if delay > 0 {
        Task {
          try? await Task.sleep(for: .milliseconds(delay))
          report(uuid)
        }
      } else {
        report(uuid)
      }
    }

    private func report(_ uuid: UUID) {
      let update = CXCallUpdate()
      update.localizedCallerName = "Smoke Test"
      update.remoteHandle = CXHandle(type: .phoneNumber, value: "+12025550123")
      provider?.reportNewIncomingCall(with: uuid, update: update) { _ in }
    }
  }

  @main
  struct SmokeApp: App {
    @UIApplicationDelegateAdaptor(SmokeDelegate.self) private var delegate

    var body: some Scene {
      WindowGroup { Text("Runtime smoke test") }
    }
  }
#endif
