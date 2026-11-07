import Foundation

/// Delivers actions to the app's JavaScript `ConversationHandler`.
///
/// The SDK performs answer, end, hold, mute and tones itself, then tells the app; it never waits
/// for JavaScript, which may not be running after a cold launch. Only starting a call, or joining
/// one from its call preview, waits for the app to place it. So a `start` or `join` is the only
/// action that a handler settles: resolving it confirms that the app placed the call, and
/// rejecting it, or missing its deadline, fails a start or returns a join to its call preview,
/// and the app's command, if any, rejects.
@MainActor
final class HandlerActions {
  enum Kind: String {
    case start, join
  }

  typealias Origin = ConversationEncoding.Origin

  /// How a gated start or join ended.
  enum Outcome {
    /// The handler placed the call, or no handler received it and unhandled actions are placed.
    case placed
    /// The handler rejected the action.
    case failed
    /// The action's deadline passed before the handler settled it.
    case expired
  }

  /// How much of the SDK's placement deadline the handler leaves for the SDK to complete the
  /// start or join.
  private static let placementMargin: TimeInterval = 1

  private struct Gated {
    let actionID: String
    let call: CallID
    let kind: Kind
    let origin: Origin
    let deadline: Date
    /// The conversation when the SDK asked for the action, until the call's current one is known.
    let conversation: JSONValue
    /// The handler generation the action was delivered to.
    var delivered: Int?
    var expiry: Task<Void, Never>?
  }

  /// Whether a start or join that no handler received before its deadline is placed anyway.
  var acceptsUnhandled = false

  /// Whether JavaScript attached a handler.
  private(set) var isAttached = false

  private var gated: [Gated] = []
  private var generation = 0
  private let send: @MainActor (String, JSONValue) -> Void
  private let conversation: @MainActor (CallID) -> JSONValue?
  private let complete: @MainActor (CallID, Kind, Outcome) -> Void
  private let expired: @MainActor () -> Void

  /// Creates the delivery.
  ///
  /// - Parameters:
  ///   - send: Sends an event to JavaScript.
  ///   - conversation: The current conversation of a call.
  ///   - complete: Places a gated call, or tells the SDK that the app didn't place it, with the
  ///     gated action's kind: `start` or `join`.
  ///   - expired: Called when a gated action's deadline passed, so its call no longer shows it.
  init(
    send: @escaping @MainActor (String, JSONValue) -> Void,
    conversation: @escaping @MainActor (CallID) -> JSONValue?,
    complete: @escaping @MainActor (CallID, Kind, Outcome) -> Void,
    expired: @escaping @MainActor () -> Void
  ) {
    self.send = send
    self.conversation = conversation
    self.complete = complete
    self.expired = expired
  }

  /// JavaScript attached or detached its handler. Only a newer generation applies; it takes over
  /// every action delivered to the one before.
  func attach(_ attached: Bool, generation next: Int) {
    guard next > generation else { return }
    withdrawDeliveries(reason: "handlerReplaced")
    generation = next
    isAttached = attached
    if attached { gated.indices.forEach(deliver) }
  }

  /// The JavaScript runtime started again, so its handlers count generations from the start.
  func reset() {
    withdrawDeliveries(reason: "handlerReplaced")
    generation = 0
    isAttached = false
  }

  /// Waits for the handler to place a call that the SDK asked the app to start or join.
  ///
  /// - Parameters:
  ///   - kind: `start` or `join`.
  ///   - call: The call to place.
  ///   - conversation: The call's conversation.
  ///   - origin: Whether the app or a system surface asked for it.
  ///   - placement: The SDK's placement deadline.
  func gate(
    _ kind: Kind, call: CallID, conversation: JSONValue, origin: Origin, placement: Duration
  ) {
    cancel(call, reason: "handlerReplaced")
    let seconds = Double(placement.components.seconds)
    let deadline = Date.now.addingTimeInterval(max(0, seconds - Self.placementMargin))
    let actionID = UUID().uuidString.lowercased()
    let expiry = Task { [weak self] in
      try? await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow))
      guard !Task.isCancelled else { return }
      self?.expire(actionID)
    }
    gated.append(
      Gated(
        actionID: actionID, call: call, kind: kind, origin: origin, deadline: deadline,
        conversation: conversation, expiry: expiry))
    deliver(gated.count - 1)
  }

  /// Settles a gated action with the handler's result.
  func settle(_ actionID: String, generation owner: Int, success: Bool) {
    guard
      let index = gated.firstIndex(where: { $0.actionID == actionID }),
      gated[index].delivered == owner, owner == generation, Date.now < gated[index].deadline
    else { return }
    let action = gated.remove(at: index)
    action.expiry?.cancel()
    complete(action.call, action.kind, success ? .placed : .failed)
  }

  /// Withdraws the gated actions of a call that no longer waits for the app.
  func cancel(_ call: CallID, reason: String) {
    gated.removeAll { action in
      guard action.call == call else { return false }
      action.expiry?.cancel()
      if let delivered = action.delivered { cancelled(action, generation: delivered, reason) }
      return true
    }
  }

  /// The call's action that waits for the handler, as the TypeScript API's `PendingAction`.
  func pending(for call: CallID) -> JSONValue? {
    gated.first { $0.call == call }.map { action in
      .object([
        "id": .string(action.actionID), "kind": .string(action.kind.rawValue),
        "origin": .string(action.origin.rawValue), "deadline": .date(action.deadline),
      ])
    }
  }

  // MARK: Delivery

  private func deliver(_ index: Int) {
    guard isAttached, Date.now < gated[index].deadline else { return }
    let action = gated[index]
    let conversation = conversation(action.call) ?? action.conversation
    gated[index].delivered = generation
    send(
      "handlerAction",
      body(
        actionID: action.actionID, kind: action.kind, origin: action.origin,
        deadline: action.deadline, conversation: conversation, arguments: [:]))
  }

  private func expire(_ actionID: String) {
    guard let index = gated.firstIndex(where: { $0.actionID == actionID }) else { return }
    let action = gated.remove(at: index)
    if let delivered = action.delivered { cancelled(action, generation: delivered, "deadline") }
    complete(
      action.call, action.kind, action.delivered == nil && acceptsUnhandled ? .placed : .expired)
    expired()
  }

  private func withdrawDeliveries(reason: String) {
    for index in gated.indices {
      if let delivered = gated[index].delivered {
        cancelled(gated[index], generation: delivered, reason)
      }
      gated[index].delivered = nil
    }
  }

  private func cancelled(_ action: Gated, generation: Int, _ reason: String) {
    send(
      "actionCancelled",
      .object([
        "actionID": .string(action.actionID), "generation": .number(Double(generation)),
        "reason": .string(reason),
      ]))
  }

  private func body(
    actionID: String, kind: Kind, origin: Origin, deadline: Date, conversation: JSONValue,
    arguments: [String: JSONValue]
  ) -> JSONValue {
    var fields = arguments
    fields["actionID"] = .string(actionID)
    fields["generation"] = .number(Double(generation))
    fields["kind"] = .string(kind.rawValue)
    fields["origin"] = .string(origin.rawValue)
    fields["deadline"] = .date(deadline)
    fields["conversation"] = conversation
    return .object(fields)
  }
}
