#if os(iOS)
  import CallKit
  import Foundation
  #if SWIFT_PACKAGE
    public import VoIPCore
  #endif

  /// The calling framework that presents calls with CallKit, Apple's earlier framework for
  /// presenting VoIP calls on the system's call screen and in Recents.
  ///
  /// `LiveCommunicationKitAdapter` is the default. Link this adapter instead when CallKit's
  /// measured behaviour is what the app needs; an app links one of the two. Apps distributed in
  /// China mainland can't present calls with CallKit.
  ///
  /// Pass it to `VoIPClient.start(framework:media:push:configuration:clock:)`. The adapter
  /// creates the app's one `CXProvider` and a `CXCallController`, names each call to the system
  /// by `deviceUUID(for:)`, and maps between the SDK's calls and CallKit's:
  ///
  /// | SDK | CallKit |
  /// |---|---|
  /// | `Action.start(_:)` and `Action.join(_:)` | `CXStartCallAction` |
  /// | `Action.answer(_:)` | `CXAnswerCallAction` |
  /// | `Action.end(_:)` | `CXEndCallAction` |
  /// | `Action.hold(_:onHold:)` | `CXSetHeldCallAction` |
  /// | `Action.mute(_:muted:)` | `CXSetMutedCallAction` |
  /// | `Action.playTones(_:digits:)` | `CXPlayDTMFCallAction` |
  /// | `Action.merge(_:with:)` and `Action.unmerge(_:)` | `CXSetGroupCallAction` |
  /// | `EndReason` | `CXCallEndedReason` |
  ///
  /// CallKit presents one handle for a call: the first party's presented handle, with the
  /// party's display name as the caller's name. It performs only the starts that the app
  /// requests; Recents and Siri open the app to start a call.
  ///
  /// The provider calls its delegate, and completes reports, on `VoIPActor.queue`, so the SDK
  /// performs the system's actions, and starts audio, without leaving `VoIPActor`. CallKit gives
  /// each action a deadline. When the system stops waiting for an action, the SDK receives
  /// `FrameworkEvent.actionTimedOut(_:)`.
  @VoIPActor
  public final class CallKitAdapter: CallingFramework {
    private var configuration = VoIPConfiguration()
    private var onEvent: (@VoIPActor (FrameworkEvent) -> Void)?
    private var provider: CXProvider?
    private var controller: CXCallController?
    private var delegate: ProviderDelegate?
    /// The call that each call UUID names. The adapter forgets a call once the system ended it.
    private var callIDs: [UUID: CallID] = [:]
    /// The starts and joins the app requested, until the system asks the SDK to perform them.
    private var requested: [UUID: Action] = [:]
    /// The actions the system asked the SDK to perform, by action UUID, until the SDK completes
    /// them.
    private var actions: [UUID: CXCallAction] = [:]
    /// Whether each call is muted, as of the last mute the SDK fulfilled, until the call ends.
    private var muted: [UUID: Bool] = [:]
    /// The incoming reports the system hasn't answered.
    private var reporting: Set<UUID> = []
    /// Ends to report once the system has answered the call's report.
    private var endsAfterReport: [UUID: EndReason] = [:]

    /// Creates the CallKit adapter.
    public nonisolated init() {}

    isolated deinit {
      // A process has one calling framework provider, which a later client's adapter takes over.
      provider?.invalidate()
    }

    // MARK: CallingFramework

    /// Creates the app's provider with the configuration.
    public func attach(
      configuration: VoIPConfiguration, onEvent: @escaping @VoIPActor (FrameworkEvent) -> Void
    ) {
      guard provider == nil else { return }
      self.configuration = configuration
      self.onEvent = onEvent
      let provider = CXProvider(configuration: CXProviderConfiguration(configuration))
      let delegate = ProviderDelegate(adapter: self)
      provider.setDelegate(delegate, queue: VoIPActor.queue)
      self.provider = provider
      self.delegate = delegate
      controller = CXCallController(queue: VoIPActor.queue)
    }

    /// Reports an incoming call to the provider before it returns.
    public func reportIncoming(
      _ call: Call, completion: @escaping @VoIPActor (PresentationOutcome) -> Void
    ) {
      guard let provider else { return completion(.refused(.refused)) }
      let uuid = uuid(for: call.id)
      reporting.insert(uuid)
      let update = CXCallUpdate(call, capabilities: configuration.capabilities)
      provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
        let outcome = SystemError.presentationOutcome(for: error)
        // The provider completes the report on its delegate queue.
        VoIPActor.assumeIsolated {
          guard let self else { return completion(outcome) }
          self.reportCompleted(uuid, outcome, then: completion)
        }
      }
    }

    /// Asks the system to perform an action the app requested.
    public func request(_ action: Action, for call: Call) async throws(ActionError) {
      guard let controller else { throw .refused }
      let uuid = uuid(for: action.callID)
      let systemAction: CXCallAction
      switch action {
      case .start(let outgoing):
        guard let start = Self.startAction(uuid, to: outgoing.parties, hasVideo: outgoing.hasVideo)
        else { throw .refused }
        requested[uuid] = action
        systemAction = start
      case .join:
        guard let start = Self.startAction(uuid, to: call.parties, hasVideo: call.hasVideo)
        else { throw .refused }
        requested[uuid] = action
        systemAction = start
      case .answer:
        systemAction = CXAnswerCallAction(call: uuid)
      case .end:
        systemAction = CXEndCallAction(call: uuid)
      case .hold(_, let onHold):
        systemAction = CXSetHeldCallAction(call: uuid, onHold: onHold)
      case .mute(_, let muted):
        systemAction = CXSetMutedCallAction(call: uuid, muted: muted)
      case .playTones(_, let digits):
        systemAction = CXPlayDTMFCallAction(call: uuid, digits: digits, type: .singleTone)
      case .merge(_, let other):
        systemAction = CXSetGroupCallAction(call: uuid, callUUIDToGroupWith: self.uuid(for: other))
      case .unmerge:
        systemAction = CXSetGroupCallAction(call: uuid, callUUIDToGroupWith: nil)
      }
      let transaction = CXTransaction(action: systemAction)
      let error = await withCheckedContinuation { continuation in
        controller.request(transaction) { continuation.resume(returning: $0) }
      }
      guard let error else { return }
      // A start or join that the system refused never made a call in the system.
      if requested[uuid] == action { forget(uuid) }
      throw SystemError.actionError(for: error)
    }

    /// Fulfils an action the system asked the SDK to perform.
    public func fulfill(_ id: ActionID) {
      complete(id, fulfilled: true)
    }

    /// Fails an action the system asked the SDK to perform.
    public func fail(_ id: ActionID) {
      complete(id, fulfilled: false)
    }

    /// Updates the call's first party and capabilities in the system.
    public func update(_ call: Call) {
      provider?.reportCall(
        with: uuid(for: call.id),
        updated: CXCallUpdate(call, capabilities: configuration.capabilities))
    }

    /// Tells the system that a call started on this device began connecting, or connected.
    public func reportOutgoing(_ id: CallID, connected: Bool) {
      let uuid = uuid(for: id)
      if connected {
        provider?.reportOutgoingCall(with: uuid, connectedAt: .now)
      } else {
        provider?.reportOutgoingCall(with: uuid, startedConnectingAt: .now)
      }
    }

    /// Tells the system that a call ended without the user ending it on this device.
    public func reportEnded(_ id: CallID, reason: EndReason) {
      let uuid = deviceUUID(for: id)
      forget(uuid)
      guard !reporting.contains(uuid) else {
        endsAfterReport[uuid] = reason
        return
      }
      provider?.reportCall(with: uuid, endedAt: .now, reason: CXCallEndedReason(reason))
    }

    // MARK: The system

    /// Asks the SDK to perform an action the system asks the provider to perform, or fails it
    /// when it names a call this device doesn't know.
    func perform(_ systemAction: CXCallAction) {
      if let mute = systemAction as? CXSetMutedCallAction, changesNothing(mute) {
        return mute.fulfill()
      }
      guard let onEvent, let action = action(for: systemAction) else {
        return systemAction.fail()
      }
      actions[systemAction.uuid] = systemAction
      onEvent(.perform(ActionID(rawValue: systemAction.uuid), action))
    }

    /// Tells the SDK that the system stopped waiting for an action it hasn't completed.
    func timedOut(_ action: CXAction) {
      guard actions.removeValue(forKey: action.uuid) != nil else { return }
      onEvent?(.actionTimedOut(ActionID(rawValue: action.uuid)))
    }

    /// Tells the SDK that the system activated or deactivated the audio session.
    func send(_ event: FrameworkEvent) {
      onEvent?(event)
    }

    /// Tells the SDK that the provider reset, which ends every call it presents.
    func reset() {
      // The system abandoned every action it was waiting for.
      actions.removeAll()
      callIDs.removeAll()
      requested.removeAll()
      muted.removeAll()
      onEvent?(.reset)
    }

    /// The SDK's action for an action the system asks the provider to perform, or `nil` when it
    /// names a call this device doesn't know.
    private func action(for systemAction: CXCallAction) -> Action? {
      let uuid = systemAction.callUUID
      if systemAction is CXStartCallAction { return requested.removeValue(forKey: uuid) }
      guard let id = callIDs[uuid] else { return nil }
      switch systemAction {
      case is CXAnswerCallAction: return .answer(id)
      case is CXEndCallAction: return .end(id)
      case let hold as CXSetHeldCallAction: return .hold(id, onHold: hold.isOnHold)
      case let mute as CXSetMutedCallAction: return .mute(id, muted: mute.isMuted)
      case let tones as CXPlayDTMFCallAction: return .playTones(id, digits: tones.digits)
      case let group as CXSetGroupCallAction:
        guard let other = group.callUUIDToGroupWith else { return .unmerge(id) }
        return callIDs[other].map { .merge(id, with: $0) }
      default: return nil
      }
    }

    /// Whether a mute changes nothing: the system repeats a mute shortly after the SDK fulfilled
    /// one, and unmutes a call after it ended.
    private func changesNothing(_ mute: CXSetMutedCallAction) -> Bool {
      let uuid = mute.callUUID
      let pending = actions.values.contains {
        ($0 as? CXSetMutedCallAction)?.callUUID == uuid
      }
      return !pending && muted[uuid, default: false] == mute.isMuted
    }

    private func reportCompleted(
      _ uuid: UUID, _ outcome: PresentationOutcome,
      then completion: @VoIPActor (PresentationOutcome) -> Void
    ) {
      reporting.remove(uuid)
      if let reason = endsAfterReport.removeValue(forKey: uuid), outcome == .presented {
        provider?.reportCall(with: uuid, endedAt: .now, reason: CXCallEndedReason(reason))
      }
      completion(outcome)
    }

    // MARK: Helpers

    /// The call UUID that names a call to the system, remembering which call it names.
    private func uuid(for id: CallID) -> UUID {
      let uuid = deviceUUID(for: id)
      callIDs[uuid] = id
      return uuid
    }

    /// Forgets a call that the system ended, or never started.
    private func forget(_ uuid: UUID) {
      callIDs[uuid] = nil
      requested[uuid] = nil
      muted[uuid] = nil
    }

    private func complete(_ id: ActionID, fulfilled: Bool) {
      guard let action = actions.removeValue(forKey: id.rawValue) else { return }
      guard fulfilled else { return action.fail() }
      switch action {
      case let mute as CXSetMutedCallAction: muted[mute.callUUID] = mute.isMuted
      case let end as CXEndCallAction: forget(end.callUUID)
      default: break
      }
      action.fulfill()
    }

    /// A start action for a call to its first party's presented handle, or `nil` when the call
    /// has no party.
    private static func startAction(
      _ uuid: UUID, to parties: [Party], hasVideo: Bool
    ) -> CXStartCallAction? {
      guard let party = parties.first else { return nil }
      let start = CXStartCallAction(call: uuid, handle: CXHandle(party.presentedHandle))
      start.isVideo = hasVideo
      return start
    }
  }
#endif
