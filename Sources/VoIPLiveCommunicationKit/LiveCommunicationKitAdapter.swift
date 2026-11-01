#if os(iOS)
  import Dispatch
  import Foundation
  import LiveCommunicationKit
  import os
  #if SWIFT_PACKAGE
    public import VoIPCore
  #endif

  /// The calling framework that presents calls with LiveCommunicationKit, Apple's framework for
  /// presenting VoIP calls on the system's call screen, in Recents and on connected devices.
  ///
  /// Pass it to `VoIPClient.start(framework:media:push:audio:observers:configuration:clock:)`.
  /// The adapter creates the app's one `ConversationManager`, names each call to the system by
  /// `deviceUUID(for:)`, and maps between the SDK's calls and LiveCommunicationKit's
  /// conversations:
  ///
  /// | SDK | LiveCommunicationKit |
  /// |---|---|
  /// | `Action.start(_:)` and `Action.join(_:)` | `StartConversationAction` |
  /// | `Action.answer(_:)` | `JoinConversationAction` |
  /// | `Action.end(_:)` | `EndConversationAction` |
  /// | `Action.hold(_:onHold:)` | `PauseConversationAction` |
  /// | `Action.mute(_:muted:)` | `MuteConversationAction` |
  /// | `Action.playTones(_:digits:)` | `PlayToneAction` |
  /// | `Action.merge(_:with:)` | `MergeConversationAction` |
  /// | `Action.unmerge(_:)` | `UnmergeConversationAction` |
  /// | `EndReason.answeredElsewhere` | `Conversation.EndedReason.joinedElsewhere` |
  ///
  /// A call reports every handle of every party, so that the system can match any of them to a
  /// contact. A call started from a system surface, such as Recents, gets the conversation's
  /// UUID as its call ID.
  ///
  /// LiveCommunicationKit gives each action a deadline, 30 seconds by default. When the system
  /// stops waiting for an action, the SDK receives `FrameworkEvent.actionTimedOut(_:)`.
  @VoIPActor
  public final class LiveCommunicationKitAdapter: CallingFramework {
    /// How long ``reportIncoming(_:completion:)`` waits for the system to answer a report.
    ///
    /// On an iPhone 13 with iOS 27.1, the system answered each of 16 reports of calls that a Focus
    /// filtered after 2,095 to 2,170 ms, so a 2-second wait always ended first. The wait outlasts
    /// that, and still ends before the PushKit source's 4-second watchdog finishes the push.
    static let reportWaitLimit: DispatchTimeInterval = .seconds(3)

    /// The adapter's log, which records why the system refused a report or an action, with the
    /// system's error domain and code, so that they can be read in Console or a sysdiagnose.
    private nonisolated static let log = Logger(
      subsystem: "VoIPLiveCommunicationKit", category: "adapter")

    private var configuration = VoIPConfiguration()
    private var onEvent: (@VoIPActor (FrameworkEvent) -> Void)?
    private var manager: SharedManager?
    private var bridge: ConversationBridge?
    /// The call each conversation UUID names.
    private var callIDs: [UUID: CallID] = [:]
    /// The conversation UUIDs of calls started from a system surface, which the system chose.
    private var systemUUIDs: [CallID: UUID] = [:]
    /// The starts and joins the app requested, until the system asks the SDK to perform them.
    private var requested: [UUID: Action] = [:]
    /// The incoming reports the system hasn't answered.
    private var reporting: Set<UUID> = []
    /// Ends to report once the system has answered the call's report.
    private var endsAfterReport: [UUID: EndReason] = [:]

    /// Creates the LiveCommunicationKit adapter.
    public nonisolated init() {}

    isolated deinit {
      // A process has one calling framework provider, which a later client's adapter takes over.
      manager?.invalidate()
    }

    // MARK: CallingFramework

    /// Creates the app's conversation manager with the configuration.
    public func attach(
      configuration: VoIPConfiguration, onEvent: @escaping @VoIPActor (FrameworkEvent) -> Void
    ) {
      guard manager == nil else { return }
      self.configuration = configuration
      self.onEvent = onEvent
      let conversationManager = ConversationManager(configuration: .init(configuration))
      let manager = SharedManager(conversationManager)
      // The stream keeps the order in which the system told the bridge.
      let (events, continuation) = AsyncStream.makeStream(of: SystemEvent.self)
      let bridge = ConversationBridge(manager: manager) { continuation.yield($0) }
      conversationManager.delegate = bridge
      self.manager = manager
      self.bridge = bridge
      Task { [weak self] in
        for await event in events { self?.receive(event) }
      }
    }

    /// Reports an incoming call, and waits until the system answers the report, for at most 3
    /// seconds.
    ///
    /// LiveCommunicationKit's report is asynchronous, but the system terminates an app whose
    /// VoIP push callback returns before the report has started (FB16655952). The report runs in
    /// its own task, which doesn't need `VoIPActor`, and the push callback returns once the
    /// system has answered it, or when the wait ends. The adapter logs how long the system took
    /// to answer, and the system's error when it didn't present the call.
    public func reportIncoming(
      _ call: Call, completion: @escaping @VoIPActor (PresentationOutcome) -> Void
    ) {
      guard let manager else { return completion(.refused(.refused)) }
      let uuid = uuid(for: call.id)
      let update = Conversation.Update(
        members: Set(call.parties.systemHandles),
        capabilities: Conversation.Capabilities(configuration.capabilities, hasVideo: call.hasVideo)
      )
      reporting.insert(uuid)
      let answered = DispatchSemaphore(value: 0)
      Task.detached(priority: .userInitiated) { [weak self] in
        let start = ContinuousClock.now
        let outcome: PresentationOutcome
        do {
          try await manager.reportNewIncomingConversation(uuid: uuid, update: update)
          outcome = .presented
          Self.log.info("The system presented an incoming report after \(start.milliseconds) ms")
        } catch {
          outcome = SystemError.presentationOutcome(for: error)
          let detail = FrameworkError(error)
          Self.log.notice(
            "The system answered an incoming report after \(start.milliseconds) ms with \(detail, privacy: .public)"
          )
        }
        answered.signal()
        if let self {
          await self.reportCompleted(uuid, outcome, then: completion)
        } else {
          await completion(outcome)
        }
      }
      if answered.wait(timeout: .now() + Self.reportWaitLimit) == .timedOut {
        Self.log.notice("The system hadn't answered an incoming report after 3 seconds")
      }
    }

    /// Asks the system to perform an action the app requested.
    ///
    /// When the system refuses, the adapter throws `ActionError.refused(_:)` with the system's
    /// error, and logs it.
    public func request(_ action: Action, for call: Call) async throws(ActionError) {
      guard let manager else { throw .refused(nil) }
      let uuid = uuid(for: action.callID)
      let systemAction: ConversationAction
      switch action {
      case .start(let outgoing):
        requested[uuid] = action
        systemAction = StartConversationAction(
          conversationUUID: uuid, handles: outgoing.parties.systemHandles,
          isVideo: outgoing.hasVideo)
      case .join:
        requested[uuid] = action
        systemAction = StartConversationAction(
          conversationUUID: uuid, handles: call.parties.systemHandles, isVideo: call.hasVideo)
      case .answer:
        systemAction = JoinConversationAction(conversationUUID: uuid)
      case .end:
        systemAction = EndConversationAction(conversationUUID: uuid)
      case .hold(_, let onHold):
        systemAction = PauseConversationAction(conversationUUID: uuid, isPaused: onHold)
      case .mute(_, let muted):
        systemAction = MuteConversationAction(conversationUUID: uuid, isMuted: muted)
      case .playTones(_, let digits):
        systemAction = PlayToneAction(conversationUUID: uuid, digits: digits, tone: .single)
      case .merge(_, let other):
        systemAction = MergeConversationAction(
          conversationUUID: uuid, conversationUUIDToMergeWith: self.uuid(for: other))
      case .unmerge:
        systemAction = UnmergeConversationAction(conversationUUID: uuid)
      }
      do {
        try await manager.perform(systemAction)
      } catch {
        if requested[uuid] == action { requested[uuid] = nil }
        let detail = FrameworkError(error)
        Self.log.error(
          "The system refused \(action.name, privacy: .public): \(detail, privacy: .public)")
        throw SystemError.actionError(for: error)
      }
    }

    /// Fulfils an action the system asked the SDK to perform.
    public func fulfill(_ id: ActionID) {
      complete(id, fulfilled: true)
    }

    /// Fails an action the system asked the SDK to perform.
    public func fail(_ id: ActionID) {
      complete(id, fulfilled: false)
    }

    /// Updates the call's parties and capabilities in the system.
    public func update(_ call: Call) {
      report(
        .conversationUpdated(
          Conversation.Update(
            members: Set(call.parties.systemHandles),
            capabilities: Conversation.Capabilities(
              configuration.capabilities, hasVideo: call.hasVideo))),
        for: uuid(for: call.id))
    }

    /// Tells the system that a call started on this device began connecting, or connected.
    public func reportOutgoing(_ id: CallID, connected: Bool) {
      report(
        connected ? .conversationConnected(.now) : .conversationStartedConnecting(.now),
        for: uuid(for: id))
    }

    /// Tells the system that a call ended without the user ending it on this device.
    public func reportEnded(_ id: CallID, reason: EndReason) {
      let uuid = uuid(for: id)
      requested[uuid] = nil
      guard !reporting.contains(uuid) else {
        endsAfterReport[uuid] = reason
        return
      }
      report(.conversationEnded(.now, Conversation.EndedReason(reason)), for: uuid)
    }

    // MARK: The system

    private func receive(_ event: SystemEvent) {
      guard let onEvent else { return }
      switch event {
      case .perform(let id, let systemAction):
        guard let action = action(for: systemAction) else { return complete(id, fulfilled: false) }
        onEvent(.perform(id, action))
      case .actionTimedOut(let id): onEvent(.actionTimedOut(id))
      case .audioActivated: onEvent(.audioActivated)
      case .audioDeactivated: onEvent(.audioDeactivated)
      case .reset:
        requested.removeAll()
        onEvent(.reset)
      }
    }

    /// The SDK's action for an action the system asks it to perform, or `nil` when it names a
    /// call this device doesn't know.
    private func action(for systemAction: SystemAction) -> Action? {
      switch systemAction {
      case .start(let uuid, let handles, let isVideo):
        if let action = requested.removeValue(forKey: uuid) { return action }
        // A start from a system surface, such as Recents.
        let parties = handles.compactMap(Party.init)
        guard !parties.isEmpty else { return nil }
        let id = callIDs[uuid] ?? CallID(rawValue: uuid.uuidString)
        callIDs[uuid] = id
        systemUUIDs[id] = uuid
        return .start(OutgoingCall(id: id, parties: parties, hasVideo: isVideo))
      case .join(let uuid): return callIDs[uuid].map { .answer($0) }
      case .end(let uuid): return callIDs[uuid].map { .end($0) }
      case .pause(let uuid, let isPaused): return callIDs[uuid].map { .hold($0, onHold: isPaused) }
      case .mute(let uuid, let isMuted): return callIDs[uuid].map { .mute($0, muted: isMuted) }
      case .playTones(let uuid, let digits):
        return callIDs[uuid].map { .playTones($0, digits: digits) }
      case .merge(let uuid, let other):
        guard let id = callIDs[uuid], let otherID = callIDs[other] else { return nil }
        return .merge(id, with: otherID)
      case .unmerge(let uuid): return callIDs[uuid].map { .unmerge($0) }
      }
    }

    private func reportCompleted(
      _ uuid: UUID, _ outcome: PresentationOutcome,
      then completion: @VoIPActor (PresentationOutcome) -> Void
    ) {
      reporting.remove(uuid)
      if let reason = endsAfterReport.removeValue(forKey: uuid), outcome == .presented {
        report(.conversationEnded(.now, Conversation.EndedReason(reason)), for: uuid)
      }
      completion(outcome)
    }

    // MARK: Helpers

    /// The conversation UUID that names a call to the system, remembering which call it names.
    private func uuid(for id: CallID) -> UUID {
      let uuid = systemUUIDs[id] ?? deviceUUID(for: id)
      callIDs[uuid] = id
      return uuid
    }

    private func complete(_ id: ActionID, fulfilled: Bool) {
      guard let bridge else { return }
      DispatchQueue.main.async { bridge.complete(id, fulfilled: fulfilled) }
    }

    private func report(_ event: Conversation.Event, for uuid: UUID) {
      guard let bridge else { return }
      DispatchQueue.main.async { bridge.report(event, for: uuid) }
    }
  }

  extension Action {
    /// The action's name for the log, without its call or parties.
    fileprivate var name: String {
      switch self {
      case .start: "a start"
      case .answer: "an answer"
      case .join: "a join"
      case .end: "an end"
      case .hold: "a hold"
      case .mute: "a mute"
      case .playTones: "tones"
      case .merge: "a merge"
      case .unmerge: "an unmerge"
      }
    }
  }

  extension ContinuousClock.Instant {
    /// The whole milliseconds since this instant.
    fileprivate var milliseconds: Int {
      Int((duration(to: .now) / .milliseconds(1)).rounded())
    }
  }
#endif
