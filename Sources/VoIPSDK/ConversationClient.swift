import Foundation

enum IncomingReportErrors {
  static func isAlreadyReported(_ error: any Error) -> Bool {
    var candidate = error as NSError
    for _ in 0..<4 {
      // Measured CallKit error wrapping remains meaningful through LCK without
      // importing or linking CallKit into the device SDK.
      if candidate.domain == "com.apple.CallKit.error.incomingcall" && candidate.code == 2 { return true }
      guard let underlying = candidate.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
      candidate = underlying
    }
    return false
  }
}

/// Carries an actual terminal delegate object through the current actor turn.
/// A new manager object wins immediately; generation checks protect UUID reuse.
struct TerminalConversationProjection<Object: AnyObject> {
  private struct Entry { let object: Object; let generation: UUID }
  private var entries: [UUID: Entry] = [:]
  @MainActor static func acceptingTerminal<Result>(_ object: Object, current: Object?,
                                                   body: @MainActor () -> Result) -> Result? {
    guard current == nil || current === object else { return nil }
    return body()
  }
  mutating func publishTerminal(_ object: Object, id: UUID) -> UUID {
    let generation = UUID()
    entries[id] = Entry(object: object, generation: generation)
    return generation
  }
  func object(for id: UUID) -> Object? { entries[id]?.object }
  mutating func project(current: [UUID: Object]) -> [UUID: Object] {
    for (id, entry) in entries {
      if let replacement = current[id], replacement !== entry.object { entries.removeValue(forKey: id) }
    }
    var projected = current
    for (id, entry) in entries where projected[id] == nil { projected[id] = entry.object }
    return projected
  }
  @discardableResult mutating func remove(_ id: UUID, generation: UUID) -> Bool {
    guard entries[id]?.generation == generation else { return false }
    entries.removeValue(forKey: id)
    return true
  }
}

/// Each actual report waits for the preceding attempt with this UUID. The Task
/// itself owns generation-checked cleanup, before any caller continuation resumes.
@MainActor
final class SerializedIncomingReports {
  struct Context {
    let previouslyReported: Bool
    let isLatest: @MainActor () -> Bool
  }
  private final class History {
    var reported: Bool
    init(_ reported: Bool) { self.reported = reported }
  }
  private struct Entry {
    let generation: UUID
    let task: Task<UUID, Error>
    let history: History
  }
  private var entries: [UUID: Entry] = [:]
  func pending(for id: UUID) -> Task<UUID, Error>? { entries[id]?.task }
  func enqueue(id: UUID, previouslyReported: Bool,
               operation: @escaping @MainActor (Context) async throws -> UUID) -> Task<UUID, Error> {
    let predecessor = entries[id]?.task
    let history = entries[id]?.history ?? History(previouslyReported)
    let generation = UUID()
    let task = Task { @MainActor [weak self] in
      if let predecessor { _ = await predecessor.result }
      let context = Context(previouslyReported: history.reported, isLatest: { [weak self] in
        self?.entries[id]?.generation == generation
      })
      defer {
        if self?.entries[id]?.generation == generation { self?.entries.removeValue(forKey: id) }
      }
      let result = try await operation(context)
      history.reported = true
      return result
    }
    entries[id] = Entry(generation: generation, task: task, history: history)
    return task
  }
}

#if canImport(LiveCommunicationKit) && (os(iOS) || os(watchOS))
import Observation
import AVFAudio
// Apple's LCK manager/actions and delegate lack concurrency annotations in Xcode 27.1.
// Keep this compatibility import here: all framework access and mutation stays on MainActor.
@preconcurrency import LiveCommunicationKit
#if SWIFT_PACKAGE
import VoIPPlatform
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
  private var terminalProjection = TerminalConversationProjection<Conversation>()
  private var recordRemovalGenerations: [UUID: UUID] = [:]
  private var refreshSuspensionDepth = 0
  private var invitations = IncomingInvitationGate()
  private let incomingReports = SerializedIncomingReports()
  private var endEventIDs: [String: Date] = [:]
  private var appActions: [UUID: Date] = [:]
  private var stateObservers: [UUID: @MainActor (ConversationStateUpdate) -> Void] = [:]
  private var publishingState = false
  private var eventObservers: [UUID: @MainActor (ConversationEvent) -> Void] = [:]
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
    if !registration.isNew && source == .foreground {
      if let pending = incomingReports.pending(for: id) { return try await pending.value }
      return id
    }
    // Register metadata before a report Task or predecessor can suspend. Every
    // PushKit delivery retains its own actual report attempt, using the same UUID.
    let existing = records[id]
    let previouslyReported = !registration.isNew && (existing == nil || existing?.seenInManager == true)
    var record = existing ?? makeRecord(direction: .incoming, members: [payload.caller], video: payload.hasVideo)
    if record.payload == nil { record.payload = payload }
    records[id] = record
    recordRemovalGenerations.removeValue(forKey: id)
    let report = incomingReports.enqueue(id: id, previouslyReported: previouslyReported) { context in
      let knownLiveConversation = self.manager.conversations.contains { $0.uuid == id }
      do {
        let update = self.update(for: self.records[id] ?? record)
        #if os(iOS) && targetEnvironment(simulator)
        SimulatorSupport.associateIncomingReport(id)
        defer { SimulatorSupport.finishIncomingReport(id) }
        #endif
        try await self.manager.reportNewIncomingConversation(uuid: id, update: update)
      } catch {
        if knownLiveConversation && self.isAlreadyReported(error) { self.refresh(); return id }
        // Only the newest queued attempt may roll back shared metadata. A
        // successful prior report leaves its intentional ended-call tombstone.
        if context.isLatest() && self.records[id]?.seenInManager != true {
          self.records.removeValue(forKey: id)
          if !context.previouslyReported { self.invitations.discardUnreported(id) }
        }
        self.refresh()
        throw error
      }
      self.refresh()
      return id
    }
    return try await report.value
  }

  @discardableResult
  public func receiveCallEnded(_ payload: CallEndedPayload) -> Bool {
    let now = Date(); endEventIDs = endEventIDs.filter { now.timeIntervalSince($0.value) <= 120 }
    guard endEventIDs[payload.eventId] == nil else { return false }
    endEventIDs[payload.eventId] = now
    guard let id = invitations.conversation(serverCallId: payload.serverCallId),
          records[id] != nil || incomingReports.pending(for: id) != nil else { return false }
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
    IncomingReportErrors.isAlreadyReported(error)
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
    guard let conversation = manager.conversations.first(where: { $0.uuid == id }) ?? terminalProjection.object(for: id),
          let record = records[id] else { return nil }
    let direction = record.direction
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
    guard refreshSuspensionDepth == 0 else { return }
    let current = manager.conversations
    let projectedObjects = terminalProjection.project(current: Dictionary(uniqueKeysWithValues: current.map { ($0.uuid, $0) }))
    let ids = Set(projectedObjects.keys)
    for conversation in current {
      recordRemovalGenerations.removeValue(forKey: conversation.uuid)
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
      scheduleRecordRemoval(id)
    }
    let projected = projectedObjects.keys.compactMap(snapshot).sorted { $0.id.uuidString < $1.id.uuidString }
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
  /// Keep metadata until queued terminal delegates have had a chance to publish it.
  private func scheduleRecordRemoval(_ id: UUID) {
    guard recordRemovalGenerations[id] == nil else { return }
    let generation = UUID()
    recordRemovalGenerations[id] = generation
    Task { @MainActor [weak self] in
      guard let self, self.recordRemovalGenerations[id] == generation else { return }
      self.recordRemovalGenerations.removeValue(forKey: id)
      guard self.terminalProjection.object(for: id) == nil,
            !self.manager.conversations.contains(where: { $0.uuid == id }),
            self.incomingReports.pending(for: id) == nil else { return }
      self.removeRecord(id)
      self.refresh()
    }
  }
  private func removeRecord(_ id: UUID) {
    recordRemovalGenerations.removeValue(forKey: id)
    // A failed/cancelled platform action may synchronously deliver its terminal
    // delegate. Keep metadata until that callback has buffered and published it.
    refreshSuspensionDepth += 1
    coordinator.cancelConversation(id)
    refreshSuspensionDepth -= 1
    guard terminalProjection.object(for: id) == nil else { return }
    records.removeValue(forKey: id); outgoingMetadata.removeValue(forKey: id)
    invitations.removeConversation(id)
  }
  private func publishTerminal(_ conversation: Conversation) {
    let id = conversation.uuid
    let current = manager.conversations.first { $0.uuid == id }
    let generation = TerminalConversationProjection<Conversation>.acceptingTerminal(conversation, current: current) {
      let generation = terminalProjection.publishTerminal(conversation, id: id)
      if records[id] == nil {
        var placeholder = makeRecord(direction: .outgoing, members: [], video: false)
        placeholder.metadataIsPlaceholder = true; placeholder.seenInManager = true
        records[id] = placeholder
      }
      recordRemovalGenerations.removeValue(forKey: id)
      // Cancel only after accepting this object identity and buffering it. A
      // stale terminal delegate must not cancel a reused UUID's pending actions.
      refreshSuspensionDepth += 1
      coordinator.cancelConversation(id)
      refreshSuspensionDepth -= 1
      return generation
    }
    guard let generation else { refresh(); return }
    refresh()
    Task { @MainActor [weak self] in
      guard let self, self.terminalProjection.remove(id, generation: generation) else { return }
      if !self.manager.conversations.contains(where: { $0.uuid == id }), self.incomingReports.pending(for: id) == nil {
        self.removeRecord(id)
      }
      self.refresh()
    }
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
    if conversation.state == .left { publishTerminal(conversation) }
    else { refresh() }
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
      if snapshot(id) == nil || snapshot(id)?.status == .ended || (!coordinator.hasPendingAction(for: id, kind: .mute) && records[id]?.muted == mute.isMuted) { action.fulfill(); return }
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
#endif
