#if os(iOS) && targetEnvironment(simulator)
  import AVFAudio
  import CKSimRuntimeC
  import Foundation
  @preconcurrency import LiveCommunicationKit

  /// An app that presents calls with one LiveCommunicationKit conversation manager and no
  /// `CXProvider`, as on the device that the runtime's multi-call policy was measured on.
  ///
  /// The test names the app's conversations A, B, C and so on. The app settles each action the
  /// system delivers by the rule for its kind: at once, after a delay, by failing, by leaving it
  /// pending, or by holding it to settle in reverse order with the next ones. It records its
  /// callbacks in the runtime's journal as `lck.fixture.*` events.
  @MainActor
  final class LCKApp: NSObject, @preconcurrency ConversationManagerDelegate {
    /// How the app settles an action.
    enum Rule {
      case immediate
      case delay(milliseconds: Int)
      case fail
      case pending
      /// Settle this action and the ones that arrive within the delay in reverse order.
      case reverse(milliseconds: Int)
    }

    // LiveCommunicationKit marks its async entry points concurrent without Sendable. The app owns
    // the manager; its delegate callbacks and the app's state stay on the main actor.
    nonisolated(unsafe) let manager: ConversationManager
    private(set) var ids: [String: UUID] = [:]
    private var rules: [String: (rule: Rule, nth: Int?)] = [:]
    private var counts: [String: Int] = [:]
    private var reversed: [ConversationAction] = []
    private let capabilities: Conversation.Capabilities

    init(
      groups: Int = 2, perGroup: Int = 1,
      capabilities: Conversation.Capabilities = [.pausing, .merging, .unmerging]
    ) {
      self.capabilities = capabilities
      manager = ConversationManager(
        configuration: .init(
          ringtoneName: nil, iconTemplateImageData: nil, maximumConversationGroups: groups,
          maximumConversationsPerConversationGroup: perGroup,
          includesConversationInRecents: false, supportsVideo: false,
          supportedHandleTypes: [.generic, .phoneNumber]))
      super.init()
      manager.delegate = self
    }

    /// The conversation's UUID, created the first time the test names it.
    func id(_ name: String) -> UUID {
      if let id = ids[name] { return id }
      let id = UUID()
      ids[name] = id
      return id
    }

    /// The conversation's state as LiveCommunicationKit describes it, or `left` once the manager
    /// no longer has it.
    func state(_ name: String) -> String {
      manager.conversations.first { $0.uuid == ids[name] }.map { String(describing: $0.state) }
        ?? "left"
    }

    /// Settles the next actions of each kind (Join, Start, Pause, End, Merge, Unmerge) by a rule.
    func settle(_ kind: String, _ rule: Rule, nth: Int? = nil) {
      rules[kind] = (rule, nth)
      counts = [:]
    }

    /// Reports an incoming conversation.
    func reportIncoming(_ name: String, handle: String? = nil) async throws {
      let id = id(name)
      let member = Handle(
        type: handle == nil ? .generic : .phoneNumber, value: handle ?? name,
        displayName: "LCK " + name)
      log("reportStarted", ["callUUID": id.uuidString])
      try await manager.reportNewIncomingConversation(
        uuid: id, update: .init(members: [member], capabilities: capabilities))
    }

    /// Starts an outgoing conversation.
    func start(_ name: String) async throws {
      try await manager.perform([
        StartConversationAction(
          conversationUUID: id(name), handles: [Handle(type: .generic, value: name)], isVideo: false
        )
      ])
    }

    /// Pauses or resumes a conversation, as the app's own controls do.
    func pause(_ name: String, _ paused: Bool) async throws {
      try await manager.perform([
        PauseConversationAction(conversationUUID: id(name), isPaused: paused)
      ])
    }

    func merge(_ name: String, with other: String) async throws {
      try await manager.perform([
        MergeConversationAction(conversationUUID: id(name), conversationUUIDToMergeWith: id(other))
      ])
    }

    func unmerge(_ name: String) async throws {
      try await manager.perform([UnmergeConversationAction(conversationUUID: id(name))])
    }

    /// Changes a conversation's capabilities.
    func update(_ name: String, capabilities: Conversation.Capabilities) throws {
      guard let conversation = manager.conversations.first(where: { $0.uuid == ids[name] }) else {
        throw RuntimeTestError("No conversation \(name)")
      }
      manager.reportConversationEvent(
        .conversationUpdated(.init(capabilities: capabilities)), for: conversation)
    }

    /// Records the manager's conversations in the journal.
    func snapshot(_ label: String) {
      log(
        "snapshot",
        [
          "label": label,
          "conversations": manager.conversations.map {
            ["callUUID": $0.uuid.uuidString, "state": String(describing: $0.state)]
          },
        ])
    }

    private func log(_ event: String, _ fields: [String: Any] = [:]) {
      var fields = fields
      fields["main"] = Thread.isMainThread
      CKSimEmit("lck.fixture." + event, fields)
    }

    private func kind(_ action: ConversationAction) -> String {
      switch action {
      case is JoinConversationAction: "Join"
      case is StartConversationAction: "Start"
      case is PauseConversationAction: "Pause"
      case is EndConversationAction: "End"
      case is MergeConversationAction: "Merge"
      case is UnmergeConversationAction: "Unmerge"
      case is MuteConversationAction: "Mute"
      default: String(describing: type(of: action))
      }
    }

    private func fields(_ action: ConversationAction) -> [String: Any] {
      var fields: [String: Any] = [
        "actionID": action.uuid.uuidString, "callUUID": action.conversationUUID.uuidString,
        "kind": kind(action),
        "advertisedDeadlineMS": action.timeoutDate.timeIntervalSince1970 * 1000,
      ]
      if let pause = action as? PauseConversationAction { fields["held"] = pause.isPaused }
      return fields
    }

    private func settle(_ action: ConversationAction, failed: Bool, policy: String) {
      if failed {
        action.fail()
      } else {
        switch action {
        case let join as JoinConversationAction: join.fulfill(dateConnected: Date())
        case let start as StartConversationAction: start.fulfill(dateStarted: Date())
        case let end as EndConversationAction: end.fulfill(dateEnded: Date())
        default: action.fulfill()
        }
      }
      var fields = fields(action)
      fields["failed"] = failed
      fields["policy"] = policy
      log("settled", fields)
      if !failed, action is StartConversationAction,
        let conversation = manager.conversations.first(where: { $0.uuid == action.conversationUUID }
        )
      {
        manager.reportConversationEvent(.conversationStartedConnecting(Date()), for: conversation)
        manager.reportConversationEvent(.conversationConnected(Date()), for: conversation)
      }
      snapshot("settled")
    }

    func conversationManager(_ manager: ConversationManager, perform action: ConversationAction) {
      let name = kind(action)
      counts[name, default: 0] += 1
      var rule = Rule.immediate
      if let configured = rules[name], configured.nth == nil || configured.nth == counts[name] {
        rule = configured.rule
      }
      var fields = fields(action)
      fields["ordinal"] = counts[name]
      log("perform", fields)
      if action is JoinConversationAction || action is StartConversationAction {
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat)
      }
      switch rule {
      case .immediate: settle(action, failed: false, policy: "immediate")
      case .fail: settle(action, failed: true, policy: "fail")
      case .pending: break
      case .delay(let milliseconds):
        Task {
          try? await Task.sleep(for: .milliseconds(milliseconds))
          settle(action, failed: false, policy: "delay")
        }
      case .reverse(let milliseconds):
        reversed.append(action)
        if reversed.count == 1 {
          Task {
            try? await Task.sleep(for: .milliseconds(milliseconds))
            let actions = reversed.reversed()
            reversed = []
            for action in actions { settle(action, failed: false, policy: "reverse") }
          }
        }
      }
    }

    func conversationManager(
      _ manager: ConversationManager, timedOutPerforming action: ConversationAction
    ) {
      log("timedOut", fields(action))
      snapshot("timedOut")
    }

    func conversationManager(
      _ manager: ConversationManager, conversationChanged conversation: Conversation
    ) {
      log(
        "changed",
        ["callUUID": conversation.uuid.uuidString, "state": String(describing: conversation.state)])
      snapshot("changed")
    }

    func conversationManagerDidBegin(_ manager: ConversationManager) { log("didBegin") }
    func conversationManagerDidReset(_ manager: ConversationManager) { log("didReset") }
    func conversationManager(
      _ manager: ConversationManager, didActivate audioSession: AVAudioSession
    ) {
      log("didActivate")
    }
    func conversationManager(
      _ manager: ConversationManager, didDeactivate audioSession: AVAudioSession
    ) { log("didDeactivate") }
  }
#endif
