#if canImport(LiveCommunicationKit) && (os(iOS) || os(watchOS))
import Foundation
import Observation
import AVFAudio
// Apple's LCK manager/actions and delegate lack concurrency annotations in Xcode 27.1.
// Keep this compatibility import here: all framework access and mutation stays on MainActor.
@preconcurrency import LiveCommunicationKit
#if SWIFT_PACKAGE
import VoIPPlatform
#endif
#if os(iOS)
@preconcurrency import CallKit
#endif

/// The process's sole LCK owner. Calling code never receives the manager or a provider.
@MainActor
public final class ConversationClient: NSObject {
  public struct Configuration: Sendable, Equatable {
    public var ringtoneName: String?
    public var iconTemplateImageData: Data?
    public var maximumConversationGroups: Int
    public var maximumConversationsPerGroup: Int
    public var includesConversationInRecents: Bool
    public var supportsVideo: Bool
    public var unhandledAction: UnhandledActionPolicy
    public init(ringtoneName: String? = nil, iconTemplateImageData: Data? = nil,
                maximumConversationGroups: Int = 2, maximumConversationsPerGroup: Int = 2,
                includesConversationInRecents: Bool = true, supportsVideo: Bool = true,
                unhandledAction: UnhandledActionPolicy = .fail) {
      self.ringtoneName = ringtoneName; self.iconTemplateImageData = iconTemplateImageData
      self.maximumConversationGroups = maximumConversationGroups
      self.maximumConversationsPerGroup = maximumConversationsPerGroup
      self.includesConversationInRecents = includesConversationInRecents
      self.supportsVideo = supportsVideo; self.unhandledAction = unhandledAction
    }
  }

  private static var configuration = Configuration()
  private static var instance: ConversationClient?
  public static func configure(_ configuration: Configuration) throws {
    guard instance == nil else { throw ConversationClientError.alreadyConfigured }
    guard configuration.maximumConversationGroups > 0, configuration.maximumConversationsPerGroup > 0 else {
      throw ConversationClientError.invalidConfiguration
    }
    self.configuration = configuration
  }
  public static var shared: ConversationClient {
    if let instance { return instance }
    let client = ConversationClient(configuration: configuration)
    instance = client
    return client
  }

  static func forApplication(configuration: Configuration) throws -> ConversationClient {
    if let instance {
      guard self.configuration == configuration else { throw ConversationClientError.alreadyConfigured }
      return instance
    }
    try configure(configuration)
    return shared
  }

  private typealias Record = ConversationRecord
  private let manager: ConversationManager
  private let coordinator: ConversationActionCoordinator
  private let configuration: Configuration
  private var records: [UUID: Record] = [:]
  private var invitations = IncomingInvitationGate()
  private var incomingReports: [UUID: Task<UUID, Error>] = [:]
  private var endEventIDs: [String: Date] = [:]
  private var appActions: [UUID: Date] = [:]
  private var stateObservers: [UUID: @MainActor (ConversationStateUpdate) -> Void] = [:]
  private var publishingState = false
  private var eventObservers: [UUID: @MainActor (ConversationEvent) -> Void] = [:]
  #if os(iOS)
  private let callObserver = CXCallObserver()
  #endif
  public private(set) var state = ConversationStateUpdate(revision: 0, conversations: [])
  public var snapshots: [ConversationSnapshot] { state.conversations }

  private init(configuration: Configuration) {
    self.configuration = configuration
    coordinator = ConversationActionCoordinator(policy: configuration.unhandledAction)
    SimulatorSupport.activateIfNeeded()
    #if DEBUG
    ProviderCreationMonitor.install { message in NSLog("VoIPSDK provider ownership: %@", message) }
    ProviderCreationMonitor.beginOwnedManagerCreation()
    #endif
    manager = ConversationManager(configuration: .init(ringtoneName: configuration.ringtoneName,
      iconTemplateImageData: configuration.iconTemplateImageData,
      maximumConversationGroups: configuration.maximumConversationGroups,
      maximumConversationsPerConversationGroup: configuration.maximumConversationsPerGroup,
      includesConversationInRecents: configuration.includesConversationInRecents,
      supportsVideo: configuration.supportsVideo,
      supportedHandleTypes: [.generic, .phoneNumber, .emailAddress]))
    super.init()
    #if DEBUG
    ProviderCreationMonitor.endOwnedManagerCreation()
    #endif
    manager.delegate = self
    #if os(iOS)
    callObserver.setDelegate(self, queue: .main)
    #endif
    coordinator.snapshot = { [weak self] id in self?.snapshot(id) }
    coordinator.didChange = { [weak self] in self?.refresh() }
    coordinator.willSettle = { [weak self] id, action, accepted in
      guard let self, accepted else { return }
      if action.kind == .mute, let muted = action.muted { self.records[id]?.muted = muted }
      if action.kind == .end { self.records[id]?.ended = .init(at: Date(), reason: .local) }
    }
    trackManager()
  }

  @discardableResult
  public func observeState(_ callback: @escaping @MainActor (ConversationStateUpdate) -> Void) -> UUID {
    let token = UUID(); stateObservers[token] = callback; callback(state); return token
  }
  public func removeStateObserver(_ token: UUID) { stateObservers.removeValue(forKey: token) }
  @discardableResult
  public func observeEvents(_ callback: @escaping @MainActor (ConversationEvent) -> Void) -> UUID {
    let token = UUID(); eventObservers[token] = callback; return token
  }
  public func removeEventObserver(_ token: UUID) { eventObservers.removeValue(forKey: token) }
  public func setConversationHandler(_ handler: ConversationHandler?) { coordinator.setHandler(handler) }

  public func startConversation(to participant: Participant, video: Bool = false,
                                metadata: [String: JSONValue]? = nil) async throws -> UUID {
    guard !participant.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ConversationClientError.invalidPayload
    }
    let id = UUID()
    // Metadata exists synchronously before perform can deliver its delegate action.
    records[id] = makeRecord(direction: .outgoing, members: [participant], video: video)
    // Outgoing metadata has no incoming payload/server identity; keep it in a separate ledger.
    outgoingMetadata[id] = metadata
    do { try await perform(.start(id, participant, video)); refresh(); return id }
    catch { if records[id]?.seenInManager != true {
      records.removeValue(forKey: id); outgoingMetadata.removeValue(forKey: id)
    }; refresh(); throw error }
  }
  private var outgoingMetadata: [UUID: [String: JSONValue]] = [:]
  public func metadata(for id: UUID) -> [String: JSONValue]? {
    records[id]?.payload?.metadata ?? outgoingMetadata[id]
  }

  public func joinConversation(_ id: UUID) async throws {
    try requireConversation(id); try await perform(.join(id))
  }
  public func endConversation(_ id: UUID) async throws {
    try requireConversation(id); try await perform(.end(id))
  }
  public func setMuted(_ id: UUID, _ muted: Bool) async throws {
    try requireConversation(id); try await perform(.mute(id, muted))
  }
  public func setHeld(_ id: UUID, _ held: Bool) async throws {
    try requireConversation(id); try await perform(.hold(id, held))
  }
  public func playTones(_ id: UUID, _ digits: String) async throws {
    try requireConversation(id)
    guard !digits.isEmpty, digits.allSatisfy({ "0123456789*#ABCDabcd".contains($0) }) else {
      throw ConversationClientError.invalidDigits
    }
    try await perform(.tones(id, digits))
  }
  public func mergeConversations(_ first: UUID, _ second: UUID) async throws {
    try requireConversation(first); try requireConversation(second)
    guard first != second else { throw ConversationClientError.unsupported }
    try await perform(.merge(first, second))
  }

  public func reportIncomingConversation(_ payload: IncomingCallPayload,
                                         source: IncomingReportSource = .foreground) async throws -> UUID {
    guard !payload.eventId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !payload.serverCallId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !payload.caller.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ConversationClientError.invalidPayload
    }
    let registration = invitations.register(eventId: payload.eventId, serverCallId: payload.serverCallId, now: Date())
    let id = registration.id
    if !registration.isNew {
      if source == .foreground {
        if let existing = incomingReports[id] { return try await existing.value }
        return id
      }
      // PushKit requires a report attempt for every valid invitation, including
      // duplicates. Reuse the UUID; do not create a second ringing conversation.
      if let existing = incomingReports[id] {
        do { _ = try await existing.value }
        catch {
          if records[id]?.seenInManager != true {
            incomingReports.removeValue(forKey: id); records.removeValue(forKey: id)
            invitations.discardUnreported(id)
            return try await reportIncomingConversation(payload, source: source)
          }
        }
      }
      let knownLiveConversation = manager.conversations.contains { $0.uuid == id }
      var record = records[id] ?? makeRecord(direction: .incoming, members: [payload.caller], video: payload.hasVideo)
      if record.payload == nil { record.payload = payload }
      records[id] = record
      do { try await manager.reportNewIncomingConversation(uuid: id, update: update(for: record)) }
      catch {
        if !knownLiveConversation && records[id]?.seenInManager != true {
          // A successful ended-call tombstone stays deduplicated, but a failed
          // required re-report must not leave a phantom incoming metadata record.
          records.removeValue(forKey: id)
        }
        guard knownLiveConversation && isAlreadyReported(error) else { throw error }
      }
      refresh(); return id
    }
    var record = makeRecord(direction: .incoming, members: [payload.caller], video: payload.hasVideo)
    record.payload = payload
    records[id] = record
    let update = update(for: record)
    let report = Task { @MainActor in
      try await self.manager.reportNewIncomingConversation(uuid: id, update: update)
      return id
    }
    incomingReports[id] = report
    do {
      let result = try await report.value
      incomingReports.removeValue(forKey: id); refresh(); return result
    } catch {
      incomingReports.removeValue(forKey: id)
      if records[id]?.seenInManager != true { records.removeValue(forKey: id); invitations.discardUnreported(id) }
      refresh(); throw error
    }
  }

  @discardableResult
  public func receiveCallEnded(_ payload: CallEndedPayload) -> Bool {
    let now = Date(); endEventIDs = endEventIDs.filter { now.timeIntervalSince($0.value) <= 120 }
    guard endEventIDs[payload.eventId] == nil else { return false }
    endEventIDs[payload.eventId] = now
    guard let id = invitations.conversation(serverCallId: payload.serverCallId),
          records[id] != nil || incomingReports[id] != nil else { return false }
    // A termination racing an incoming report is retained until the manager publishes the conversation.
    records[id]?.ended = .init(at: now, reason: payload.reason)
    records[id]?.endReportPending = true
    refresh()
    return true
  }

  public func reportConversation(_ id: UUID, report: ConversationReport) throws {
    guard let conversation = manager.conversations.first(where: { $0.uuid == id }), records[id] != nil else {
      throw ConversationClientError.unknownConversation
    }
    let now = Date()
    switch report {
    case .connecting:
      records[id]?.connecting = true
      manager.reportConversationEvent(.conversationStartedConnecting(now), for: conversation)
    case .connected:
      records[id]?.connecting = false; records[id]?.connectedAt = now
      manager.reportConversationEvent(.conversationConnected(now), for: conversation)
    case .updated(let members, let video):
      if let members, members.contains(where: { $0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
        throw ConversationClientError.invalidPayload
      }
      if let members { records[id]?.members = members }
      if let video { records[id]?.video = video }
      if let record = records[id] { manager.reportConversationEvent(.conversationUpdated(update(for: record)), for: conversation) }
    case .ended(let reason):
      records[id]?.ended = .init(at: now, reason: reason)
      manager.reportConversationEvent(.conversationEnded(now, endedReason(reason)), for: conversation)
    }
    refresh()
  }

  private enum Command: Sendable {
    case start(UUID, Participant, Bool), join(UUID), end(UUID), mute(UUID, Bool)
    case hold(UUID, Bool), tones(UUID, String), merge(UUID, UUID)
  }
  private func perform(_ command: Command) async throws {
    // Fresh action objects stay local to this submission. Passing a Swift-owned,
    // actor-isolated action array between methods would require an unsafe transfer.
    let action: ConversationAction
    switch command {
    case .start(let id, let participant, let video):
      action = StartConversationAction(conversationUUID: id, handles: [handle(participant)], isVideo: video)
    case .join(let id): action = JoinConversationAction(conversationUUID: id)
    case .end(let id): action = EndConversationAction(conversationUUID: id)
    case .mute(let id, let muted): action = MuteConversationAction(conversationUUID: id, isMuted: muted)
    case .hold(let id, let held): action = PauseConversationAction(conversationUUID: id, isPaused: held)
    case .tones(let id, let digits): action = PlayToneAction(conversationUUID: id, digits: digits, tone: .single)
    case .merge(let first, let second):
      action = MergeConversationAction(conversationUUID: first, conversationUUIDToMergeWith: second)
    }
    let id = action.uuid
    appActions = appActions.filter { $0.value > Date() }
    appActions[id] = action.timeoutDate
    do { try await manager.perform([action]) }
    catch { appActions.removeValue(forKey: id); throw error }
  }
  private func isAlreadyReported(_ error: any Error) -> Bool {
    #if os(iOS)
    var candidate = error as NSError
    for _ in 0..<4 {
      if candidate.domain == CXErrorDomainIncomingCall &&
          candidate.code == CXErrorCodeIncomingCallError.callUUIDAlreadyExists.rawValue { return true }
      guard let underlying = candidate.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
      candidate = underlying
    }
    #endif
    return false
  }
  private func requireConversation(_ id: UUID) throws {
    guard manager.conversations.contains(where: { $0.uuid == id && $0.state != .left }) else {
      throw ConversationClientError.unknownConversation
    }
  }
  private func makeRecord(direction: ConversationDirection, members: [Participant], video: Bool) -> Record {
    Record(direction: direction, members: members,
      capabilities: .init(video: configuration.supportsVideo), video: video)
  }
  private func handle(_ participant: Participant) -> Handle {
    if let phone = participant.phoneNumber { return Handle(type: .phoneNumber, value: phone, displayName: participant.displayName) }
    if let email = participant.email { return Handle(type: .emailAddress, value: email, displayName: participant.displayName) }
    return Handle(type: .generic, value: participant.id, displayName: participant.displayName)
  }
  private func update(for record: Record) -> Conversation.Update {
    var capabilities: Conversation.Capabilities = []
    if record.capabilities.hold { capabilities.insert(.pausing) }
    if record.capabilities.merge { capabilities.formUnion([.merging, .unmerging]) }
    if record.capabilities.tones { capabilities.insert(.playingTones) }
    // LCK's video flag describes this conversation, not the app's ability to upgrade.
    if record.video { capabilities.insert(.video) }
    return .init(members: Set(record.members.map(handle)), capabilities: capabilities)
  }
  private func endedReason(_ reason: ConversationEndedReason) -> Conversation.EndedReason {
    switch reason {
    case .local, .remoteEnded: .remoteEnded
    case .failed: .failed
    case .unanswered: .unanswered
    case .answeredElsewhere: .joinedElsewhere
    case .declinedElsewhere: .declinedElsewhere
    }
  }
  private func snapshot(_ id: UUID) -> ConversationSnapshot? {
    guard let conversation = manager.conversations.first(where: { $0.uuid == id }), let record = records[id] else { return nil }
    var direction = record.direction
    #if os(iOS)
    if let call = callObserver.calls.first(where: { $0.uuid == id }) { direction = call.isOutgoing ? .outgoing : .incoming }
    #endif
    let status: ConversationStatus
    switch conversation.state {
    case .idle: status = record.connecting ? .connecting : direction == .incoming ? .ringing : .dialing
    case .joining: status = .connecting
    case .joined: status = .connected
    case .paused: status = .held
    case .leaving: status = .ending
    case .left: status = .ended
    @unknown default: status = .connecting
    }
    return ConversationSnapshot(id: id, direction: direction, status: status, members: record.members,
      capabilities: record.capabilities, isMuted: record.muted, isVideo: record.video,
      connectedAt: record.connectedAt, ended: record.ended, payload: record.payload,
      pending: coordinator.pending(for: id))
  }
  private func refresh() {
    let current = manager.conversations
    let ids = Set(current.map(\.uuid))
    for conversation in current {
      if records[conversation.uuid] == nil {
        // LCK only exposes localMember; it must never be mislabeled as a remote party.
        var placeholder = makeRecord(direction: .outgoing, members: [], video: false)
        placeholder.metadataIsPlaceholder = true
        records[conversation.uuid] = placeholder
      }
      records[conversation.uuid]?.seenInManager = true
      if let payload = records[conversation.uuid]?.payload {
        invitations.markActive(conversation.uuid, serverCallId: payload.serverCallId, now: Date())
      }
      if records[conversation.uuid]?.endReportPending == true,
         let ended = records[conversation.uuid]?.ended, conversation.state != .left {
        records[conversation.uuid]?.endReportPending = false
        manager.reportConversationEvent(.conversationEnded(ended.at, endedReason(ended.reason)), for: conversation)
      }
    }
    for (id, record) in records where record.seenInManager && !ids.contains(id) {
      records.removeValue(forKey: id); outgoingMetadata.removeValue(forKey: id)
      invitations.removeConversation(id); coordinator.cancelConversation(id)
    }
    let projected = current.compactMap { snapshot($0.uuid) }.sorted { $0.id.uuidString < $1.id.uuidString }
    guard projected != state.conversations else { return }
    state = ConversationStateUpdate(revision: state.revision &+ 1, conversations: projected)
    guard !publishingState else { return }
    publishingState = true
    var update = state
    while true {
      for callback in Array(stateObservers.values) { callback(update) }
      guard update.revision != state.revision else { break }
      update = state
    }
    publishingState = false
  }
  private func trackManager() {
    withObservationTracking { refresh(); _ = manager.conversations } onChange: { [weak self] in
      Task { @MainActor in self?.trackManager() }
    }
  }
  private func emit(_ event: ConversationEvent) { for callback in Array(eventObservers.values) { callback(event) } }
}

// Device traces prove all LCK delegate callbacks arrive on main. @preconcurrency limits
// the missing SDK isolation annotation to these witnesses; it adds a runtime actor check.
extension ConversationClient: @preconcurrency ConversationManagerDelegate {
  public func conversationManager(_ manager: ConversationManager, conversationChanged conversation: Conversation) {
    if conversation.state == .left { coordinator.cancelConversation(conversation.uuid) }
    refresh()
  }
  public func conversationManagerDidBegin(_ manager: ConversationManager) { refresh() }
  public func conversationManagerDidReset(_ manager: ConversationManager) {
    coordinator.cancelAll(reason: .reset); appActions.removeAll(); refresh(); emit(.providerReset)
  }
  public func conversationManager(_ manager: ConversationManager, perform action: ConversationAction) {
    switch action.state { case .idle, .running: break; default: return }
    let id = action.conversationUUID
    let origin: ConversationActionOrigin = appActions.removeValue(forKey: action.uuid) == nil ? .system : .app
    if let start = action as? StartConversationAction, records[id]?.metadataIsPlaceholder != false {
      let members = start.handles.map { handle -> Participant in
        Participant(id: handle.value, displayName: handle.displayName,
          phoneNumber: handle.type == .phoneNumber ? handle.value : nil,
          email: handle.type == .emailAddress ? handle.value : nil)
      }
      if records[id] == nil { records[id] = makeRecord(direction: .outgoing, members: members, video: start.isVideo) }
      else { records[id]?.enrichSystemStart(members: members, video: start.isVideo) }
    }
    refresh()
    let kind: ConversationActionKind
    var held: Bool?; var muted: Bool?; var digits: String?
    switch action {
    case is JoinConversationAction: kind = .join
    case is StartConversationAction: kind = .start
    case is EndConversationAction: kind = .end
    case let pause as PauseConversationAction:
      kind = .hold; held = pause.isPaused
      if !coordinator.hasPendingAction(for: id, kind: .hold),
         let snapshot = snapshot(id), (snapshot.status == .held) == pause.isPaused { action.fulfill(); return }
    case let mute as MuteConversationAction:
      kind = .mute; muted = mute.isMuted
      if snapshot(id) == nil || (!coordinator.hasPendingAction(for: id, kind: .mute) && records[id]?.muted == mute.isMuted) { action.fulfill(); return }
    case let tone as PlayToneAction: kind = .tones; digits = tone.digits
    case is MergeConversationAction, is UnmergeConversationAction:
      // RFC has no merge handler; LCK owns topology. No transport/media work is fabricated.
      action.fulfill(); return
    default: action.fail(); return
    }
    let pending = PendingAction(id: action.uuid, kind: kind, deadline: action.timeoutDate,
      origin: origin, held: held, muted: muted, digits: digits)
    coordinator.enqueue(conversationID: id, action: pending, isPending: {
      switch action.state { case .idle, .running: true; default: false }
    }, settle: { accepted in if accepted { action.fulfill() } else { action.fail() } })
  }
  public func conversationManager(_ manager: ConversationManager, timedOutPerforming action: ConversationAction) {
    coordinator.cancel(action.uuid, reason: .platformTimeout)
  }
  public func conversationManager(_ manager: ConversationManager, didActivate audioSession: AVAudioSession) { emit(.audioActivated) }
  public func conversationManager(_ manager: ConversationManager, didDeactivate audioSession: AVAudioSession) { emit(.audioDeactivated) }
}
#if os(iOS)
extension ConversationClient: @preconcurrency CXCallObserverDelegate {
  public func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) { refresh() }
}
#endif
#endif
