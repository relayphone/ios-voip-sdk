import Foundation

/// Cooperative cancellation also covers handlers that do not inspect Task cancellation.
@MainActor
public final class ConversationCancellationSignal {
  public enum Reason: String, Sendable { case deadline, replaced, cancelled, platformTimeout, reset }
  public private(set) var reason: Reason?
  public var isCancelled: Bool { reason != nil }
  private var observers: [UUID: @MainActor (Reason) -> Void] = [:]

  @discardableResult public func observe(_ callback: @escaping @MainActor (Reason) -> Void) -> UUID {
    let id = UUID()
    if let reason { callback(reason) } else { observers[id] = callback }
    return id
  }
  public func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
  public func throwIfCancelled() throws { if isCancelled { throw CancellationError() } }
  func cancel(_ reason: Reason) {
    guard self.reason == nil else { return }
    self.reason = reason
    let callbacks = Array(observers.values); observers.removeAll()
    for callback in callbacks { callback(reason) }
  }
}

@MainActor
public struct ConversationActionContext {
  public let actionID: UUID
  /// Application policy deadline, initially 1.5 seconds before the platform timeout.
  public let deadline: Date
  public let origin: ConversationActionOrigin
  public let signal: ConversationCancellationSignal
  public let held: Bool?
  public let muted: Bool?
  public let digits: String?
}

@MainActor
public struct ConversationHandler {
  public typealias Action = @MainActor (ConversationSnapshot, ConversationActionContext) async throws -> Void
  public var join: Action
  public var start: Action
  public var end: Action
  public var hold: Action?
  public var mute: Action?
  public var tones: Action?

  public init(join: @escaping Action, start: @escaping Action, end: @escaping Action,
              hold: Action? = nil, mute: Action? = nil, tones: Action? = nil) {
    self.join = join; self.start = start; self.end = end
    self.hold = hold; self.mute = mute; self.tones = tones
  }

  func implementation(for kind: ConversationActionKind) -> Action? {
    switch kind {
    case .join: join
    case .start: start
    case .end: end
    case .hold: hold
    case .mute: mute
    case .tones: tones
    case .merge, .unmerge: nil
    }
  }
}

/// Keeps platform objects behind closures; the coordinator has no framework/threading assumptions.
@MainActor
final class ConversationActionCoordinator {
  typealias Schedule = @MainActor (Date, @escaping @MainActor () -> Void) -> @MainActor () -> Void
  private static let deadlineMargin: TimeInterval = 1.5
  #if DEBUG && targetEnvironment(simulator)
  struct Diagnostic {
    let phase: String
    let actionID: String
    let wallTimeMS: Int
    let effectiveDeadlineMS: Int
    let platformDeadlineMS: Int
    let entryPending: Bool
    let platformPending: Bool
  }
  static var diagnosticSink: (@MainActor (Diagnostic) -> Void)?
  #endif
  private final class Entry {
    let conversationID: UUID
    let action: PendingAction
    let platformDeadline: Date
    let isPending: @MainActor () -> Bool
    let settle: @MainActor (Bool) -> Void
    var cancelTimer: (@MainActor () -> Void)?
    var task: Task<Void, Never>?
    var signal: ConversationCancellationSignal?
    var delivery: UUID?
    init(conversationID: UUID, action: PendingAction, platformDeadline: Date, isPending: @escaping @MainActor () -> Bool,
         settle: @escaping @MainActor (Bool) -> Void) {
      self.conversationID = conversationID; self.action = action
      self.platformDeadline = platformDeadline
      self.isPending = isPending; self.settle = settle
    }
  }
  private let policy: UnhandledActionPolicy
  private let now: @MainActor () -> Date
  private let schedule: Schedule
  private var entries: [UUID: Entry] = [:]
  private var handler: ConversationHandler?
  private var handlerGeneration: UInt64 = 0
  var snapshot: (@MainActor (UUID) -> ConversationSnapshot?)?
  var didChange: (@MainActor () -> Void)?
  var willSettle: (@MainActor (UUID, PendingAction, Bool) -> Void)?

  init(policy: UnhandledActionPolicy, now: @escaping @MainActor () -> Date = { Date() }, schedule: Schedule? = nil) {
    self.policy = policy; self.now = now
    self.schedule = schedule ?? { deadline, fire in
      let task = Task { @MainActor in
        do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)), tolerance: .zero) }
        catch { return }
        guard !Task.isCancelled else { return }
        fire()
      }
      return { task.cancel() }
    }
  }

  func hasPendingAction(for id: UUID, kind: ConversationActionKind) -> Bool {
    entries.values.contains { $0.conversationID == id && $0.action.kind == kind }
  }

  func pending(for id: UUID) -> PendingAction? {
    entries.values.filter { $0.conversationID == id }.map(\.action).sorted {
      if $0.deadline != $1.deadline { return $0.deadline < $1.deadline }
      return $0.id.uuidString < $1.id.uuidString
    }.first
  }

  func enqueue(conversationID: UUID, action: PendingAction,
               isPending: @escaping @MainActor () -> Bool, settle: @escaping @MainActor (Bool) -> Void) {
    guard entries[action.id] == nil else { return }
    let platformDeadline = action.deadline
    var action = action
    action.deadline = platformDeadline.addingTimeInterval(-Self.deadlineMargin)
    let entry = Entry(conversationID: conversationID, action: action, platformDeadline: platformDeadline,
      isPending: isPending, settle: settle)
    entries[action.id] = entry
    if action.deadline <= now() { expire(action.id); return }
    entry.cancelTimer = schedule(action.deadline) { [weak self] in self?.expire(action.id) }
    didChange?()
    deliver(entry)
  }

  func setHandler(_ handler: ConversationHandler?) {
    self.handler = handler
    handlerGeneration &+= 1
    let generation = handlerGeneration
    // Detach first: signal observers may synchronously replace the handler again.
    for entry in Array(entries.values) {
      let oldSignal = entry.signal; let oldTask = entry.task
      entry.delivery = nil; entry.signal = nil; entry.task = nil
      oldSignal?.cancel(.replaced); oldTask?.cancel()
      guard handlerGeneration == generation else { return }
    }
    for entry in Array(entries.values) {
      guard handlerGeneration == generation else { return }
      if entry.action.deadline <= now() { expire(entry.action.id) }
      else { deliver(entry) }
    }
  }

  func cancel(_ id: UUID, reason: ConversationCancellationSignal.Reason, settle: Bool = false) {
    guard let entry = entries.removeValue(forKey: id) else { return }
    entry.cancelTimer?(); entry.signal?.cancel(reason); entry.task?.cancel()
    if settle && entry.isPending() { entry.settle(false) }
    didChange?()
  }

  func cancelAll(reason: ConversationCancellationSignal.Reason) {
    for id in Array(entries.keys) { cancel(id, reason: reason, settle: true) }
  }

  func cancelConversation(_ id: UUID, except actionID: UUID? = nil) {
    for entry in Array(entries.values) where entry.conversationID == id && entry.action.id != actionID {
      cancel(entry.action.id, reason: .cancelled, settle: true)
    }
  }

  private func deliver(_ entry: Entry) {
    guard let handler, entries[entry.action.id] === entry, entry.delivery == nil else { return }
    guard entry.isPending() else { cancel(entry.action.id, reason: .cancelled); return }
    guard let conversation = snapshot?(entry.conversationID) else {
      finish(entry, accepted: false); return
    }
    guard let implementation = handler.implementation(for: entry.action.kind) else {
      // Only join/start/end require application work. Optional operations accept by default.
      finish(entry, accepted: ![.join, .start, .end].contains(entry.action.kind)); return
    }
    let delivery = UUID(); let signal = ConversationCancellationSignal()
    entry.delivery = delivery; entry.signal = signal
    let action = entry.action
    let context = ConversationActionContext(actionID: action.id, deadline: action.deadline,
      origin: action.origin, signal: signal, held: action.held, muted: action.muted, digits: action.digits)
    entry.task = Task { @MainActor [weak self] in
      // Do not retain the entry/platform action across uncooperative application code.
      guard !Task.isCancelled, self?.canInvoke(action.id, delivery: delivery) == true else { return }
      let accepted: Bool
      do { try await implementation(conversation, context); accepted = true } catch { accepted = false }
      guard let self, let entry = self.entries[action.id],
            entry.delivery == delivery, !Task.isCancelled else { return }
      if action.deadline <= self.now() { self.expire(action.id) }
      else { self.finish(entry, accepted: accepted) }
    }
  }

  private func canInvoke(_ id: UUID, delivery: UUID) -> Bool {
    guard let entry = entries[id], entry.delivery == delivery else { return false }
    guard entry.isPending() else { cancel(id, reason: .cancelled); return false }
    guard entry.action.deadline > now() else { expire(id); return false }
    return true
  }

  private func expire(_ id: UUID) {
    guard let entry = entries[id] else { return }
    #if DEBUG && targetEnvironment(simulator)
    diagnose("policy-fire", entry)
    #endif
    let wasDelivered = entry.delivery != nil
    finish(entry, accepted: !wasDelivered && policy == .accept, cancellation: .deadline)
  }

  private func finish(_ entry: Entry, accepted: Bool,
                      cancellation: ConversationCancellationSignal.Reason? = nil) {
    guard entries.removeValue(forKey: entry.action.id) != nil else { return }
    entry.cancelTimer?()
    if let cancellation { entry.signal?.cancel(cancellation) }
    entry.task?.cancel()
    // A platform timeout/state change wins; fulfillment cannot resurrect a settled action.
    if entry.isPending() {
      let accepted = accepted && now() < entry.platformDeadline
      // Install accepted mute/end metadata before fulfillment can synchronously
      // emit conversationChanged or a system echo.
      willSettle?(entry.conversationID, entry.action, accepted)
      #if DEBUG && targetEnvironment(simulator)
      diagnose("platform-settle-enter", entry)
      #endif
      entry.settle(accepted)
      #if DEBUG && targetEnvironment(simulator)
      diagnose("platform-settle-return", entry)
      #endif
    }
    didChange?()
    #if DEBUG && targetEnvironment(simulator)
    diagnose("pending-state-published", entry)
    #endif
  }

  #if DEBUG && targetEnvironment(simulator)
  private func diagnose(_ phase: String, _ entry: Entry) {
    guard let sink = Self.diagnosticSink else { return }
    sink(.init(phase: phase, actionID: entry.action.id.uuidString,
      wallTimeMS: Int(Date().timeIntervalSince1970 * 1000),
      effectiveDeadlineMS: Int(entry.action.deadline.timeIntervalSince1970 * 1000),
      platformDeadlineMS: Int(entry.platformDeadline.timeIntervalSince1970 * 1000),
      entryPending: entries[entry.action.id] != nil, platformPending: entry.isPending()))
  }
  #endif
}
