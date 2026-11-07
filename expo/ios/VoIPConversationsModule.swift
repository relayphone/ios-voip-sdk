public import ExpoModulesCore
import Foundation
import Synchronization

/// The `VoIPConversations` native module: the TypeScript API's `NativeTransport` on iOS.
///
/// It forwards every call to ``CallService``, which runs the SDK's client from launch. Expo calls
/// the module from its own threads, and the module keeps no state of its own; it only sends
/// events, which ExpoModulesCore delivers on the JavaScript thread.
public final class VoIPConversationsModule: Module, @unchecked Sendable {
  public func definition() -> ModuleDefinition {
    Name("VoIPConversations")

    Events(
      "conversationsChanged", "audioRoutesChanged", "pushTokenUpdated", "handlerAction",
      "actionCancelled", "conversationEvent", "callPreviewActivitiesChanged",
      "focusFilterStateChanged")

    OnCreate { [weak self] in
      guard let self else { return }
      let owner = ObjectIdentifier(self)
      onMain { [weak self] service in
        service.attach(owner: owner) { name, body in
          self?.sendEvent(name, body.foundationObject)
        }
      }
    }

    OnDestroy {
      let owner = ObjectIdentifier(self)
      onMain { $0.detach(owner: owner) }
    }

    OnStartObserving("conversationEvent") {
      onMain { $0.observeConversationEvents(true) }
    }

    OnStopObserving("conversationEvent") {
      onMain { $0.observeConversationEvents(false) }
    }

    Property("snapshot") { () -> [String: Any] in
      CallService.snapshot.withLock { $0 }.foundationObject
    }

    Property("mediaAdapter") { () -> String in
      Settings.main.mediaAdapter.rawValue
    }

    AsyncFunction("getConversations") { () async -> [String: Any] in
      await CallService.shared.snapshotNow().foundationObject
    }

    AsyncFunction("getAudioRoutes") { () async -> [String: Any] in
      await CallService.shared.audioRoutes.foundationObject
    }

    AsyncFunction("getPushToken") { () async -> [String: Any] in
      await CallService.shared.pushToken.foundationObject
    }

    AsyncFunction("getCallPreviewActivities") { () async -> [String: Any] in
      await CallService.shared.callPreviewActivities.foundationObject
    }

    AsyncFunction("getFocusFilterState") { () async -> [String: Any] in
      await CallService.shared.focusFilterState.foundationObject
    }

    AsyncFunction("startConversation") { (options: [String: Any]) async throws -> String in
      let options = try json(options)
      return try await bridged { try await CallService.shared.startConversation(options) }
    }

    AsyncFunction("joinConversation") { (id: String) async throws in
      try await bridged { try await CallService.shared.joinConversation(id) }
    }

    AsyncFunction("endConversation") { (id: String) async throws in
      try await bridged { try await CallService.shared.endConversation(id) }
    }

    AsyncFunction("setHeld") { (id: String, held: Bool) async throws in
      try await bridged { try await CallService.shared.setHeld(id, held) }
    }

    AsyncFunction("setMuted") { (id: String, muted: Bool) async throws in
      try await bridged { try await CallService.shared.setMuted(id, muted) }
    }

    AsyncFunction("playTones") { (id: String, digits: String) async throws in
      try await bridged { try await CallService.shared.playTones(id, digits) }
    }

    AsyncFunction("mergeConversations") { (first: String, second: String) async throws in
      try await bridged { try await CallService.shared.mergeConversations(first, second) }
    }

    AsyncFunction("reportConversation") { (id: String, report: [String: Any]) async throws in
      let report = try json(report)
      try await bridged { try await CallService.shared.reportConversation(id, report) }
    }

    AsyncFunction("reportIncomingConversation") {
      (payload: [String: Any]) async throws -> [String: Any] in
      let payload = try json(payload)
      return try await bridged {
        try await CallService.shared.reportIncomingConversation(payload)
      }.foundationObject
    }

    AsyncFunction("receiveCallEnded") { (payload: [String: Any]) async throws -> Bool in
      let payload = try json(payload)
      return try await bridged { try await CallService.shared.receiveCallEnded(payload) }
    }

    AsyncFunction("selectAudioRoute") { (id: String) async throws in
      try await bridged { try await CallService.shared.selectAudioRoute(id) }
    }

    Function("setHandlerAttached") { (attached: Bool, generation: Int) in
      onMain { $0.setHandlerAttached(attached, generation: generation) }
    }

    Function("settleAction") {
      (actionID: String, generation: Int, success: Bool, _: [String: Any]?) in
      onMain { $0.settleAction(actionID, generation: generation, success: success) }
    }
  }
}

/// Runs work on the main actor in the order that JavaScript asked for it.
private let mainCommands = MainActorCommands()

private struct MainActorCommands: Sendable {
  typealias Work = @MainActor @Sendable (CallService) -> Void
  let continuation: AsyncStream<Work>.Continuation

  init() {
    let (stream, continuation) = AsyncStream.makeStream(of: Work.self)
    self.continuation = continuation
    Task { @MainActor in
      for await work in stream { work(CallService.shared) }
    }
  }

  func flush() async {
    await withCheckedContinuation { continuation in
      self.continuation.yield { _ in continuation.resume() }
    }
  }
}

private func onMain(_ work: @escaping MainActorCommands.Work) {
  mainCommands.continuation.yield(work)
}

/// Runs a command, throwing its failure as the error that JavaScript receives.
private func bridged<Result: Sendable>(_ command: () async throws -> Result) async throws -> Result
{
  await mainCommands.flush()
  do {
    return try await command()
  } catch let error as CommandError {
    throw error.exception
  }
}

/// Converts arguments from JavaScript, or throws the TypeScript API's invalid arguments error.
private func json(_ value: [String: Any]) throws -> JSONValue {
  guard let json = JSONValue(value) else { throw CommandError.invalidArguments.exception }
  return json
}

extension CommandError {
  /// The error that JavaScript receives.
  var exception: Exception { ConversationException(self) }
}

/// A command's failure as an Expo exception. The TypeScript API decodes the failure from the
/// message's `expo-conversation:` line.
///
/// Expo builds the JavaScript error's message from the exception's `reason`, not from its
/// `description`, so the failure goes in `reason`.
private final class ConversationException: Exception, @unchecked Sendable {
  private let details: String

  init(_ error: CommandError) {
    let details = (try? error.json.data()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    self.details = details
    super.init(
      name: "ConversationError", description: "expo-conversation:\(details)",
      code: error.code.rawValue)
  }

  override var reason: String {
    "expo-conversation:\(details)"
  }
}
