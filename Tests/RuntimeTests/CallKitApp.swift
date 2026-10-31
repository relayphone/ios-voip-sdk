#if os(iOS) && targetEnvironment(simulator)
  @preconcurrency import CallKit
  import CKSimRuntimeC
  import Foundation
  @preconcurrency import PushKit
  import Synchronization

  /// An app that presents calls with CallKit directly, as apps without the SDK do: a provider, a
  /// call controller and a PushKit registry on the main queue.
  ///
  /// A VoIP push reports an incoming call with the push's `callUUID`, from `+12025550123`, and a
  /// push whose `operation` is `outgoing` also starts an outgoing call. The app fulfills every
  /// action after 120 ms, except that it fails tones. It records each report's completion in the
  /// runtime's journal as `fixture.reportCompleted`.
  /// How many times one report's completion was called.
  private final class Replies: Sendable {
    private let count = Mutex(0)

    func next() -> Int {
      count.withLock {
        $0 += 1
        return $0
      }
    }
  }

  @MainActor
  final class CallKitApp: NSObject, @preconcurrency CXProviderDelegate,
    @preconcurrency PKPushRegistryDelegate
  {
    static let handle = "+12025550123"

    let provider: CXProvider
    let controller = CXCallController(queue: .main)
    private let registry = PKPushRegistry(queue: .main)

    override init() {
      let configuration = CXProviderConfiguration()
      configuration.maximumCallGroups = 3
      configuration.maximumCallsPerCallGroup = 3
      provider = CXProvider(configuration: configuration)
      super.init()
      provider.setDelegate(self, queue: .main)
      registry.delegate = self
      registry.desiredPushTypes = [.voIP]
    }

    /// Stops receiving pushes and invalidates the provider.
    func stop() {
      registry.desiredPushTypes = []
      registry.delegate = nil
      provider.invalidate()
    }

    /// Reports an incoming call and records the completion, with how many times this report's
    /// completion was called.
    func ring(_ uuid: UUID = UUID()) {
      let entered = ContinuousClock.now
      let update = CXCallUpdate()
      update.localizedCallerName = "Alex Morgan"
      update.remoteHandle = CXHandle(type: .phoneNumber, value: Self.handle)
      update.supportsHolding = true
      let replies = Replies()
      provider.reportNewIncomingCall(with: uuid, update: update) { error in
        let observed = error as NSError?
        let main = Thread.isMainThread
        let latency = entered.duration(to: .now) / .milliseconds(1)
        let count = replies.next()
        Task { @MainActor in
          CKSimEmit(
            "fixture.reportCompleted",
            [
              "callUUID": uuid.uuidString, "handle": Self.handle,
              "domain": observed?.domain ?? "", "code": observed?.code ?? 0, "replyCount": count,
              "main": main, "latencyMS": latency,
            ])
        }
      }
    }

    func providerDidReset(_ provider: CXProvider) {}

    func pushRegistry(
      _ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials,
      for type: PKPushType
    ) {}

    func pushRegistry(
      _ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
      for type: PKPushType, completion: @escaping () -> Void
    ) {
      let fields = payload.dictionaryPayload
      ring((fields["callUUID"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID())
      if fields["operation"] as? String == "outgoing" {
        controller.request(
          CXTransaction(
            action: CXStartCallAction(
              call: UUID(), handle: CXHandle(type: .generic, value: "Taylor"))
          )
        ) { _ in }
      }
      completion()
    }

    func provider(_ provider: CXProvider, execute transaction: CXTransaction) -> Bool {
      for action in transaction.actions {
        Task {
          try? await Task.sleep(for: .milliseconds(120))
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
#endif
