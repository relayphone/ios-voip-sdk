#if os(iOS)
  import AVFAudio
  import Foundation
  import LiveCommunicationKit
  #if SWIFT_PACKAGE
    import VoIPCore
  #endif

  /// LiveCommunicationKit's conversation manager, which has no concurrency annotations.
  ///
  /// Reporting an incoming conversation and performing actions are asynchronous requests to the
  /// call service, which the adapter makes from `VoIPActor` or a task of its own, so
  /// that a VoIP push's report never waits for the main actor. Everything else uses the manager on
  /// the main actor, where it calls its delegate.
  final class SharedManager: @unchecked Sendable {
    private let manager: ConversationManager

    init(_ manager: ConversationManager) {
      self.manager = manager
    }

    /// The manager, for use on the main actor.
    @MainActor var onMain: ConversationManager { manager }

    func reportNewIncomingConversation(uuid: UUID, update: Conversation.Update) async throws {
      try await manager.reportNewIncomingConversation(uuid: uuid, update: update)
    }

    func perform(_ action: sending ConversationAction) async throws {
      try await manager.perform([action])
    }

    /// Stops the manager, so that the system no longer presents calls through it.
    func invalidate() {
      DispatchQueue.main.async { self.onMain.invalidate() }
    }
  }

  /// Something the system told the adapter, in values that can leave the main actor.
  enum SystemEvent: Sendable {
    case perform(ActionID, SystemAction)
    case actionTimedOut(ActionID)
    case audioActivated
    case audioDeactivated
    case reset
  }

  /// An action the system asks the SDK to perform, by conversation UUID.
  enum SystemAction: Sendable {
    case start(UUID, handles: [SystemHandle], isVideo: Bool)
    case join(UUID)
    case end(UUID)
    case pause(UUID, isPaused: Bool)
    case mute(UUID, isMuted: Bool)
    case playTones(UUID, digits: String)
    case merge(UUID, with: UUID)
    case unmerge(UUID)

    init?(_ action: ConversationAction) {
      let id = action.conversationUUID
      switch action {
      case let start as StartConversationAction:
        self = .start(id, handles: start.handles, isVideo: start.isVideo)
      case is JoinConversationAction: self = .join(id)
      case is EndConversationAction: self = .end(id)
      case let pause as PauseConversationAction: self = .pause(id, isPaused: pause.isPaused)
      case let mute as MuteConversationAction: self = .mute(id, isMuted: mute.isMuted)
      case let tones as PlayToneAction: self = .playTones(id, digits: tones.digits)
      case let merge as MergeConversationAction:
        self = .merge(id, with: merge.conversationUUIDToMergeWith)
      case is UnmergeConversationAction: self = .unmerge(id)
      default: return nil
      }
    }
  }

  /// The manager's delegate, and the actions the system asked the SDK to perform until the SDK
  /// completes them.
  ///
  /// LiveCommunicationKit calls its delegate on the main actor, so the actions stay there. The
  /// bridge tells the adapter what happened with ``SystemEvent`` values.
  @MainActor
  final class ConversationBridge: @preconcurrency ConversationManagerDelegate {
    private let manager: SharedManager
    private let send: @Sendable (SystemEvent) -> Void
    /// The actions the SDK hasn't completed, by action UUID.
    private var actions: [UUID: ConversationAction] = [:]
    /// Whether each conversation is muted, as of the last mute the SDK fulfilled.
    private var muted: [UUID: Bool] = [:]

    nonisolated init(manager: SharedManager, send: @escaping @Sendable (SystemEvent) -> Void) {
      self.manager = manager
      self.send = send
    }

    /// Completes an action the system asked the SDK to perform.
    func complete(_ id: ActionID, fulfilled: Bool) {
      guard let action = actions.removeValue(forKey: id.rawValue) else { return }
      guard fulfilled else { return action.fail() }
      if let mute = action as? MuteConversationAction {
        muted[mute.conversationUUID] = mute.isMuted
      }
      action.fulfill()
    }

    /// Tells the system about a change to a conversation it presents.
    func report(_ event: Conversation.Event, for id: UUID) {
      let manager = manager.onMain
      guard let conversation = manager.conversations.first(where: { $0.uuid == id }) else { return }
      manager.reportConversationEvent(event, for: conversation)
    }

    /// Whether a mute changes nothing: the system repeats a mute shortly after the SDK fulfilled
    /// one, and unmutes a call after it ended.
    private func changesNothing(_ mute: MuteConversationAction) -> Bool {
      let id = mute.conversationUUID
      guard
        let conversation = manager.onMain.conversations.first(where: { $0.uuid == id }),
        conversation.state != .left
      else { return true }
      let pending = actions.values.contains {
        ($0 as? MuteConversationAction)?.conversationUUID == id
      }
      return !pending && muted[id, default: false] == mute.isMuted
    }

    // MARK: ConversationManagerDelegate

    func conversationManager(
      _ manager: ConversationManager, conversationChanged conversation: Conversation
    ) {
      // The SDK keeps every call's state itself.
      if conversation.state == .left { muted[conversation.uuid] = nil }
    }

    func conversationManagerDidBegin(_ manager: ConversationManager) {}

    func conversationManagerDidReset(_ manager: ConversationManager) {
      // The system abandoned every action it was waiting for.
      actions.removeAll()
      muted.removeAll()
      send(.reset)
    }

    func conversationManager(_ manager: ConversationManager, perform action: ConversationAction) {
      guard action.state == .idle || action.state == .running else { return }
      if let mute = action as? MuteConversationAction, changesNothing(mute) {
        return action.fulfill()
      }
      guard let value = SystemAction(action) else { return action.fail() }
      actions[action.uuid] = action
      send(.perform(ActionID(rawValue: action.uuid), value))
    }

    func conversationManager(
      _ manager: ConversationManager, timedOutPerforming action: ConversationAction
    ) {
      guard actions.removeValue(forKey: action.uuid) != nil else { return }
      send(.actionTimedOut(ActionID(rawValue: action.uuid)))
    }

    func conversationManager(
      _ manager: ConversationManager, didActivate audioSession: AVAudioSession
    ) {
      send(.audioActivated)
    }

    func conversationManager(
      _ manager: ConversationManager, didDeactivate audioSession: AVAudioSession
    ) {
      send(.audioDeactivated)
    }
  }
#endif
