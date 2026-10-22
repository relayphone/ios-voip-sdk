import Foundation
import Observation
import Dispatch

// These controls execute the real Client, Handler, activation coordinator and
// adapter operation ordering. Only framework/platform edges below are inert.
// Duplicate-image ownership and native audio behavior have separate controls.
@MainActor enum ProcessSDKOwnership {
  private static var claimed = false
  static func claim() throws { claimed = true }
}

@MainActor enum HostClientOwner {
  static func acquire() -> ConversationClient {
    let client = try! ConversationClient.forApplication(configuration: .init())
    client.finishLaunch()
    return client
  }
}

private let hostAudioQueue = DispatchQueue(label: "VoIPSDK.HostMuteAudioBoundary")
func VSAudioSessionGetQueue() -> DispatchQueue { hostAudioQueue }

extension AudioSessionQueue {
  public func configureForConversation() throws {
    try Self.checkCancellation()
  }
}

enum SystemAudioLifecycleEvent: Sendable {
  case active, inactive, mediaServicesReset, resumptionRecommended(Bool)
}

@MainActor final class SystemAudioSession {
  let routes = AudioRoutesStore()
  var onLifecycle: (@MainActor (SystemAudioLifecycleEvent) -> Void)?
  private(set) var authorized = false
  func setSystemAudioAuthorization(_ active: Bool) { authorized = active }
  func refreshRoutes() {}
  func selectRoute(_ id: String, isActive: Bool) async throws {
    _ = try routes.selection(id, isActive: isActive)
  }
}

// Test-only LCK boundary. The production client and handler remain unchanged.
public struct Handle: Hashable, Sendable {
  public enum Kind: Sendable { case generic, phoneNumber, emailAddress }
  public let type: Kind
  public let value: String
  public let displayName: String?
  public init(type: Kind, value: String, displayName: String?) {
    self.type = type; self.value = value; self.displayName = displayName
  }
}
@MainActor public final class AVAudioSession {}
@MainActor public final class Conversation {
  public enum State { case idle, joining, joined, paused, leaving, left }
  public struct Capabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let pausing = Self(rawValue: 1), merging = Self(rawValue: 2)
    public static let playingTones = Self(rawValue: 4), video = Self(rawValue: 8)
    public static let unmerging = Self(rawValue: 16)
  }
  public struct Update: Sendable { public let members: Set<Handle>; public let capabilities: Capabilities }
  public enum EndedReason: Equatable { case remoteEnded, failed, unanswered, joinedElsewhere, declinedElsewhere }
  public enum Event {
    case conversationStartedConnecting(Date), conversationConnected(Date)
    case conversationUpdated(Update), conversationEnded(Date, EndedReason)
  }
  public let uuid: UUID
  public var state: State
  init(_ id: UUID, state: State) { uuid = id; self.state = state }
}
@MainActor public class ConversationAction {
  public enum State { case idle, running, complete, failed }
  public let uuid = UUID()
  public let conversationUUID: UUID
  public var timeoutDate = Date().addingTimeInterval(30)
  public private(set) var state: State = .idle
  public private(set) var settlements = 0
  private var waiter: CheckedContinuation<Void, any Error>?
  var whenFulfilled: (@MainActor () -> Void)?
  init(conversationUUID: UUID) { self.conversationUUID = conversationUUID }
  func running() { state = .running }
  public func fulfill() { settle(true) }
  public func fail() { settle(false) }
  private func settle(_ accepted: Bool) {
    guard state == .idle || state == .running else { preconditionFailure("Platform action settled twice") }
    settlements += 1; state = accepted ? .complete : .failed
    if accepted { whenFulfilled?() }
    if accepted { waiter?.resume() } else { waiter?.resume(throwing: PlatformFailure.rejected) }
    waiter = nil
  }
  func wait() async throws {
    if state == .complete { return }
    if state == .failed { throw PlatformFailure.rejected }
    try await withCheckedThrowingContinuation { waiter = $0 }
  }
}
@MainActor public final class JoinConversationAction: ConversationAction {}
@MainActor public final class EndConversationAction: ConversationAction {}
@MainActor public final class UnmergeConversationAction: ConversationAction {}
@MainActor public final class StartConversationAction: ConversationAction {
  public let handles: [Handle]; public let isVideo: Bool
  init(conversationUUID: UUID, handles: [Handle], isVideo: Bool) {
    self.handles = handles; self.isVideo = isVideo; super.init(conversationUUID: conversationUUID)
  }
}
@MainActor public final class MuteConversationAction: ConversationAction {
  public let isMuted: Bool
  init(conversationUUID: UUID, isMuted: Bool) { self.isMuted = isMuted; super.init(conversationUUID: conversationUUID) }
}
@MainActor public final class PauseConversationAction: ConversationAction {
  public let isPaused: Bool
  init(conversationUUID: UUID, isPaused: Bool) { self.isPaused = isPaused; super.init(conversationUUID: conversationUUID) }
}
@MainActor public final class PlayToneAction: ConversationAction {
  public enum Tone { case single }
  public let digits: String
  init(conversationUUID: UUID, digits: String, tone: Tone) { self.digits = digits; super.init(conversationUUID: conversationUUID) }
}
@MainActor public final class MergeConversationAction: ConversationAction {
  init(conversationUUID: UUID, conversationUUIDToMergeWith: UUID) { super.init(conversationUUID: conversationUUID) }
}
public protocol ConversationManagerDelegate: AnyObject {
  func conversationManager(_ manager: ConversationManager, conversationChanged conversation: Conversation)
  func conversationManagerDidBegin(_ manager: ConversationManager)
  func conversationManagerDidReset(_ manager: ConversationManager)
  func conversationManager(_ manager: ConversationManager, perform action: ConversationAction)
  func conversationManager(_ manager: ConversationManager, timedOutPerforming action: ConversationAction)
  func conversationManager(_ manager: ConversationManager, didActivate audioSession: AVAudioSession)
  func conversationManager(_ manager: ConversationManager, didDeactivate audioSession: AVAudioSession)
}
// Only this modeled incoming edge can run outside MainActor. Record entry and
// settle its errors under a lock; mock conversation publication then returns to
// the actor protecting the rest of this facade. These controls do not measure
// genuine LCK scheduling or the separate blocked-main PushKit acceptance.
private final class HostIncomingReports: @unchecked Sendable {
  struct State {
    var errors: [any Error] = []
    var reported: [UUID] = []
    var paused = false
    var work: CheckedContinuation<Void, Never>?
  }
  private let lock = NSLock()
  private var state = State()
  func withState<Value>(_ operation: (inout State) -> Value) -> Value {
    lock.lock()
    defer { lock.unlock() }
    return operation(&state)
  }
}

@Observable @MainActor public final class ConversationManager {
  public struct Configuration {
    public init(ringtoneName: String?, iconTemplateImageData: Data?, maximumConversationGroups: Int,
                maximumConversationsPerConversationGroup: Int, includesConversationInRecents: Bool,
                supportsVideo: Bool, supportedHandleTypes: [Handle.Kind]) {}
  }
  static var latest: ConversationManager?
  public weak var delegate: (any ConversationManagerDelegate)?
  public var conversations: [Conversation] = []
  var nextTimeout: TimeInterval?
  var appActions: [ConversationAction] = []
  var reports: [(UUID, Conversation.Event)] = []
  @ObservationIgnored nonisolated private let incoming = HostIncomingReports()
  var incomingErrors: [any Error] {
    get { incoming.withState { $0.errors } }
    set { incoming.withState { $0.errors = newValue } }
  }
  var reportedIncoming: [UUID] { incoming.withState { $0.reported } }
  var pauseIncoming: Bool {
    get { incoming.withState { $0.paused } }
    set { incoming.withState { $0.paused = newValue } }
  }
  var incomingWork: CheckedContinuation<Void, Never>? {
    get { incoming.withState { $0.work } }
    set { incoming.withState { $0.work = newValue } }
  }
  public init(configuration: Configuration) { Self.latest = self }
  public func perform(_ actions: [ConversationAction]) async throws {
    precondition(actions.count == 1)
    let action = actions[0]
    if let timeout = nextTimeout { action.timeoutDate = Date().addingTimeInterval(timeout); nextTimeout = nil }
    if action is StartConversationAction { conversations.append(Conversation(action.conversationUUID, state: .idle)) }
    action.whenFulfilled = { [weak self, weak action] in
      guard let self, let action,
            let conversation = self.conversations.first(where: { $0.uuid == action.conversationUUID }) else { return }
      // Genuine reference Start fulfillment can remain idle; Join becomes joined.
      if action is JoinConversationAction { conversation.state = .joined }
      if action is EndConversationAction { conversation.state = .left }
      self.delegate?.conversationManager(self, conversationChanged: conversation)
    }
    appActions.append(action)
    deliver(action)
    try await action.wait()
  }
  func deliver(_ action: ConversationAction) {
    action.running()
    delegate?.conversationManager(self, perform: action)
  }
  public nonisolated func reportNewIncomingConversation(uuid: UUID, update: Conversation.Update) async throws {
    let paused = incoming.withState { state in
      state.reported.append(uuid)
      return state.paused
    }
    if paused {
      await withCheckedContinuation { continuation in incoming.withState { $0.work = continuation } }
    }
    let error = incoming.withState { $0.errors.isEmpty ? nil : $0.errors.removeFirst() }
    if let error { throw error }
    await publishIncoming(uuid)
  }
  private func publishIncoming(_ uuid: UUID) {
    conversations.append(Conversation(uuid, state: .idle))
  }
  public func reportConversationEvent(_ event: Conversation.Event, for conversation: Conversation) {
    reports.append((conversation.uuid, event))
    if case .conversationConnected = event { conversation.state = .joined }
    if case .conversationEnded = event { conversation.state = .left }
    delegate?.conversationManager(self, conversationChanged: conversation)
  }
}
enum PlatformFailure: Error { case rejected }
