// @exact/calls on iOS through ios-voip-sdk. Exact's runner keeps the call list and hands it here
// (`exact:listed`). `CallListBridge` follows it with `VoIPClient`, and this module carries what the
// bridge asks of Exact back as `exact-choice:` and `exact-report:` topics.
import ExactPackage
import Foundation

public final class VoIPCallsModule: ExactPackage {
  private let context: ExactPackageContext

  public init(context: ExactPackageContext) {
    self.context = context
    if !context.agent { MainActor.assumeIsolated { VoIPCallHost.shared.attach(self) } }
  }

  /// The app's VoIP push token, for its server, from an app module's Swift.
  @MainActor public static func pushTokens() -> AsyncStream<Data?> {
    VoIPCallHost.shared.push.tokens()
  }

  public func later(
    _ name: String, _ args: [String: Any], preferred: Any?, reply: @escaping ([String: Any]) -> Void
  ) {
    switch name {
    case "exact:listed":
      if !context.agent {
        let entries = (args["entries"] as? [[String: Any]] ?? []).compactMap {
          entry -> CallListEntry? in
          let decoded = CallListEntry(listed: entry)
          if decoded == nil {
            context.log("voip: an entry that doesn't decode: \(entry["id"] ?? "?")")
          }
          return decoded
        }
        MainActor.assumeIsolated { VoIPCallHost.shared.bridge.follow(entries) }
      }
      reply([:])
    case "callsStatus": reply(status())
    default: reply(["error": "NotSupportedError"])
    }
  }

  public func call(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
    name == "callsStatusSync" ? status() : ["error": "NotSupportedError"]
  }

  private func status() -> [String: Any] { ["available": true, "systemUI": !context.agent] }

  func choose(_ id: CallID, _ choice: CallListChoice) {
    tell(
      "exact-choice:",
      ["extension": "calls", "state": "calls", "key": id.rawValue, "choice": choice.rawValue])
  }

  func report(_ entry: CallListEntry) {
    let handle = entry.party.presentedHandle
    var args: [String: Any] = [
      "id": entry.id.rawValue, "handle": handle.value, "handleType": handle.kind.listed,
      "video": entry.hasVideo,
    ]
    if let name = entry.party.displayName { args["displayName"] = name }
    tell("exact-report:", ["extension": "calls", "send": "reportIncomingCall", "args": args])
  }

  private func tell(_ prefix: String, _ body: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: body),
      let text = String(data: data, encoding: .utf8)
    else { return }
    context.changed(prefix + text)
  }

  var audioSession: ExactAudioSession { context.audioSession }
  func log(_ line: String) { context.log(line) }
}

/// The app's media is its own; the host's audio owner is told of the call's audio by the module.
// swift-format-ignore: UseSynthesizedInitializer
private struct ExactCallMedia: CallMedia {
  nonisolated init() {}
  func prepare(_ call: Call) async throws {}
  func activate() {}
  func deactivate() {}
}

/// The process's one client, since a process has one calling framework provider. Main thread.
@MainActor
final class VoIPCallHost {
  static let shared = VoIPCallHost()

  let bridge = CallListBridge()
  let push = PushKitSource()
  private var client: VoIPClient?
  private weak var module: VoIPCallsModule?
  private var claim: ExactSubscription?
  private var outputs: Task<Void, Never>?

  func attach(_ module: VoIPCallsModule) {
    self.module = module
    guard client == nil else { return }
    outputs = Task { [bridge, weak self] in
      for await output in bridge.outputs { self?.apply(output) }
    }
    do {
      client = try VoIPClient.start(
        framework: LiveCommunicationKitAdapter(), media: ExactCallMedia(), push: push,
        observers: [bridge], configuration: VoIPConfiguration(supportsVideo: true))
    } catch { module.log("voip: VoIPClient did not start: \(error)") }
  }

  private func apply(_ output: CallListBridge.Output) {
    guard let module else { return }
    switch output {
    case .choice(let id, let choice): module.choose(id, choice)
    case .report(let entry): module.report(entry)
    case .claimAudio(let hasVideo):
      claim = module.audioSession.claimCall(video: hasVideo) { _ in }
    case .releaseAudio:
      claim?.cancel()
      claim = nil
    case .audioActive(let active): module.audioSession.callAudio(active)
    case .refused(let id, let error): module.log("voip: \(id.rawValue) refused: \(error)")
    }
  }
}

extension CallListEntry {
  /// One of the runner's entries, or `nil` for one that doesn't name a valid call.
  fileprivate init?(listed entry: [String: Any]) {
    guard let id = entry["id"] as? String,
      let state = (entry["state"] as? String).flatMap(CallListState.init(rawValue:)),
      let value = entry["handle"] as? String
    else { return nil }
    let kind: Handle.Kind =
      switch entry["handleType"] as? String {
      case "phoneNumber": .phoneNumber
      case "emailAddress": .emailAddress
      default: .generic
      }
    guard let handle = try? Handle(kind: kind, value: value) else { return nil }
    self.init(
      id: CallID(rawValue: id),
      party: Party(handle: handle, displayName: entry["displayName"] as? String),
      isIncoming: entry["direction"] as? String == "incoming",
      hasVideo: entry["video"] as? Bool ?? false,
      state: state, isMuted: entry["muted"] as? Bool ?? false,
      endedReason: (entry["endedReason"] as? String).flatMap(CallListEndReason.init(rawValue:)))
  }
}

extension Handle.Kind {
  fileprivate var listed: String {
    switch self {
    case .phoneNumber: "phoneNumber"
    case .emailAddress: "emailAddress"
    case .generic: "generic"
    }
  }
}

/// `VSPushCompletion`'s behaviour in Swift, since an Exact package compiles Swift sources only.
final class VSPushCompletion: NSObject, @unchecked Sendable {
  private let lock = NSLock()
  private var completion: (() -> Void)?

  init(completion: @escaping () -> Void, watchdog: TimeInterval) {
    self.completion = completion
    super.init()
    DispatchQueue.global().asyncAfter(deadline: .now() + watchdog) { [self] in finish() }
  }

  func finish() {
    lock.lock()
    let body = completion
    completion = nil
    lock.unlock()
    body?()
  }
}
