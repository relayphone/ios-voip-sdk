// An app that uses CallKit and PushKit directly and doesn't link the runtime. The runtime smoke
// test launches it with the packaged runtime injected and drives a call with `cksim`.
#if targetEnvironment(simulator)
  @preconcurrency import CallKit
  @preconcurrency import PushKit
  import SwiftUI

  @MainActor
  final class SmokeDelegate: NSObject, UIApplicationDelegate, @preconcurrency CXProviderDelegate,
    @preconcurrency PKPushRegistryDelegate
  {
    private var provider: CXProvider?
    private var registry: PKPushRegistry?

    func application(
      _ application: UIApplication,
      didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
      let provider = CXProvider(configuration: CXProviderConfiguration())
      provider.setDelegate(self, queue: .main)
      self.provider = provider
      let registry = PKPushRegistry(queue: .main)
      registry.delegate = self
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
      let update = CXCallUpdate()
      update.localizedCallerName = "Smoke Test"
      update.remoteHandle = CXHandle(type: .phoneNumber, value: "+12025550123")
      provider?.reportNewIncomingCall(with: UUID(), update: update) { _ in }
      completion()
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
