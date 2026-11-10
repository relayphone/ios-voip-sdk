import Foundation

#if SWIFT_PACKAGE
  public import VoIPCore
#endif

/// The state of a call in Exact's call list.
public enum CallListState: String, Hashable, Sendable {
  case ringing, dialing, connecting, connected, held, ended
}

/// Why a call in Exact's call list ended.
public enum CallListEndReason: String, Hashable, Sendable {
  case local, remote, unanswered, declined, failed, answeredElsewhere, declinedElsewhere
}

/// A call in Exact's call list, as the runner hands it over.
public struct CallListEntry: Hashable, Sendable {
  public var id: CallID
  public var party: Party
  public var isIncoming: Bool
  public var hasVideo: Bool
  public var state: CallListState
  public var isMuted: Bool
  public var endedReason: CallListEndReason?

  public init(
    id: CallID, party: Party, isIncoming: Bool, hasVideo: Bool = false, state: CallListState,
    isMuted: Bool = false, endedReason: CallListEndReason? = nil
  ) {
    self.id = id
    self.party = party
    self.isIncoming = isIncoming
    self.hasVideo = hasVideo
    self.state = state
    self.isMuted = isMuted
    self.endedReason = endedReason
  }
}

/// One of the choices `@exact/calls` declares for a listed call.
public enum CallListChoice: String, Hashable, Sendable {
  case answer, hangup, hold, unhold, mute, unmute, failed, activated, deactivated
}

/// Follows Exact's call list with a ``VoIPClient``.
///
/// The runner owns the list. Each change the app makes to it becomes a request to the SDK, and
/// what the person does on the system's screen comes back as one of the list's declared choices.
/// A call the platform started, such as one a VoIP push rang, is reported so that it joins the
/// list.
///
/// Pass the bridge to ``VoIPClient/start(framework:media:push:audio:observers:configuration:clock:)``
/// in `observers`, so that it sees the first events of a cold launch.
@MainActor
public final class CallListBridge: CallObserver {
  /// What the bridge asks of Exact.
  public enum Output: Hashable, Sendable {
    /// The person acted on the system's screen, or the SDK ended the call.
    case choice(CallID, CallListChoice)
    /// The platform started a call that the list doesn't have.
    case report(CallListEntry)
    /// A call needs the host's audio session.
    case claimAudio(hasVideo: Bool)
    /// No call needs the host's audio session any more.
    case releaseAudio
    /// The system activated or deactivated the audio session for calls.
    case audioActive(Bool)
    /// The SDK refused a change the app made to the list, whose call then fails.
    case refused(CallID, ActionError)
  }

  private enum Act: Hashable {
    case start, answer, end, hold, unhold, mute, unmute
  }

  /// What the bridge asks of Exact, in order. There is one consumer.
  public let outputs: AsyncStream<Output>

  private let continuation: AsyncStream<Output>.Continuation
  /// Not retained: the client keeps its observers for its life.
  private weak var client: VoIPClient?
  private var eventsTask: Task<Void, Never>?
  private var last: [CallID: CallListEntry] = [:]
  /// Actions the list asked of the SDK, whose `performed` report nothing back.
  private var asked: [CallID: Set<Act>] = [:]
  /// The person's acts on the system's screen, whose echo in the list asks nothing.
  private var person: [CallID: Set<Act>] = [:]
  /// A connecting or connected report that arrived before the SDK placed the outgoing call.
  private var early: [CallID: ServerEvent] = [:]
  private var placed: Set<CallID> = []
  /// Calls reported to the runner, whose first listing asks nothing.
  private var reported: Set<CallID> = []
  private var claimsAudio = false

  public nonisolated init() {
    (outputs, continuation) = AsyncStream.makeStream(of: Output.self)
  }

  isolated deinit {
    eventsTask?.cancel()
    continuation.finish()
  }

  public func attach(to client: VoIPClient) {
    self.client = client
    let events = client.events()
    eventsTask = Task { [weak self] in
      for await event in events { self?.handle(event) }
    }
  }

  /// Applies the runner's list as it is now: each change since the last becomes the SDK's.
  public func follow(_ entries: [CallListEntry]) {
    for entry in entries {
      let previous = last.updateValue(entry, forKey: entry.id)
      guard let previous else {
        begin(entry)
        continue
      }
      if entry.state != previous.state { move(entry, from: previous.state) }
      if entry.isMuted != previous.isMuted {
        let act: Act = entry.isMuted ? .mute : .unmute
        if !isEcho(act, of: entry.id) {
          request(.mute(entry.id, muted: entry.isMuted), act, id: entry.id)
        }
      }
    }
    let listed = Set(entries.map(\.id))
    for id in last.keys where !listed.contains(id) { forget(id) }
    if last.values.allSatisfy({ $0.state == .ended }) { releaseAudio() }
  }

  private func begin(_ entry: CallListEntry) {
    if reported.remove(entry.id) != nil { return }
    guard entry.state != .ended, let client else { return }
    if entry.isIncoming {
      let call = IncomingCall(id: entry.id, parties: [entry.party], hasVideo: entry.hasVideo)
      Task { _ = await client.report(call) }
      return
    }
    if entry.state == .connected { early[entry.id] = .connected }
    if entry.state == .connecting { early[entry.id] = .connecting }
    claimAudio(hasVideo: entry.hasVideo)
    let call = OutgoingCall(id: entry.id, parties: [entry.party], hasVideo: entry.hasVideo)
    request(.start(call), .start, id: entry.id)
  }

  private func move(_ entry: CallListEntry, from previous: CallListState) {
    switch (previous, entry.state) {
    case (_, .ended): ended(entry)
    case (.ringing, .connected):
      if !isEcho(.answer, of: entry.id) {
        claimAudio(hasVideo: entry.hasVideo)
        request(.answer(entry.id), .answer, id: entry.id)
      }
    case (.held, .connected):
      if !isEcho(.unhold, of: entry.id) {
        request(.hold(entry.id, onHold: false), .unhold, id: entry.id)
      }
    case (_, .held):
      if !isEcho(.hold, of: entry.id) {
        request(.hold(entry.id, onHold: true), .hold, id: entry.id)
      }
    case (_, .connecting): send(.connecting, for: entry.id)
    case (_, .connected): send(.connected, for: entry.id)
    default: break
    }
  }

  private func ended(_ entry: CallListEntry) {
    if isEcho(.end, of: entry.id) { return }
    switch entry.endedReason ?? .local {
    case .local, .declined: request(.end(entry.id), .end, id: entry.id)
    case .remote: send(.endedRemotely, for: entry.id)
    case .unanswered: send(.unanswered, for: entry.id)
    case .answeredElsewhere: send(.answeredElsewhere, for: entry.id)
    case .declinedElsewhere: send(.declinedElsewhere, for: entry.id)
    case .failed: send(.failed, for: entry.id)
    }
  }

  private func forget(_ id: CallID) {
    last[id] = nil
    asked[id] = nil
    person[id] = nil
    early[id] = nil
    placed.remove(id)
  }

  private func isEcho(_ act: Act, of id: CallID) -> Bool {
    person[id]?.remove(act) != nil
  }

  private func request(_ action: Action, _ act: Act, id: CallID) {
    guard let client else { return }
    asked[id, default: []].insert(act)
    Task {
      do throws(ActionError) {
        try await client.request(action)
      } catch {
        asked[id]?.remove(act)
        continuation.yield(.refused(id, error))
        continuation.yield(.choice(id, .failed))
      }
    }
  }

  private func send(_ event: ServerEvent, for id: CallID) {
    guard let client else { return }
    guard last[id]?.isIncoming == true || placed.contains(id) else {
      early[id] = event
      return
    }
    Task { await client.receive(event, for: id, eventID: Self.newEventID()) }
  }

  private static func newEventID() -> EventID { EventID(rawValue: UUID().uuidString) }

  private func handle(_ event: CallEvent) {
    switch event {
    case .presented(let call): presented(call)
    case .startRequested(let call): placeOutgoing(call.id)
    case .performed(let action, _): performed(action)
    case .audioActivated: audio(active: true)
    case .audioDeactivated: audio(active: false)
    case .ended(let call): endedBySDK(call)
    default: break
    }
  }

  private func presented(_ call: Call) {
    guard last[call.id] == nil, call.isIncoming, let party = call.parties.first else { return }
    reported.insert(call.id)
    continuation.yield(
      .report(
        CallListEntry(
          id: call.id, party: party, isIncoming: true, hasVideo: call.hasVideo, state: .ringing)))
  }

  private func placeOutgoing(_ id: CallID) {
    guard let client else { return }
    Task {
      await client.confirmPlaced(id)
      placed.insert(id)
      if let event = early.removeValue(forKey: id) {
        await client.receive(event, for: id, eventID: Self.newEventID())
      }
    }
  }

  private func performed(_ action: Action) {
    let (act, choice): (Act, CallListChoice)
    switch action {
    case .answer: (act, choice) = (.answer, .answer)
    case .end: (act, choice) = (.end, .hangup)
    case .hold(_, let onHold): (act, choice) = onHold ? (.hold, .hold) : (.unhold, .unhold)
    case .mute(_, let muted): (act, choice) = muted ? (.mute, .mute) : (.unmute, .unmute)
    default: return
    }
    let id = action.callID
    // Exact's answered call is connected at once; the app's own media follows.
    if act == .answer, let client {
      Task { await client.receive(.connected, for: id, eventID: Self.newEventID()) }
    }
    if asked[id]?.remove(act) != nil { return }
    if act == .answer { claimAudio(hasVideo: last[id]?.hasVideo ?? false) }
    person[id, default: []].insert(act)
    continuation.yield(.choice(id, choice))
  }

  private func audio(active: Bool) {
    continuation.yield(.audioActive(active))
    let states: Set<CallListState> = active ? [.connected] : [.connected, .held]
    for entry in last.values where states.contains(entry.state) {
      continuation.yield(.choice(entry.id, active ? .activated : .deactivated))
    }
  }

  private func endedBySDK(_ call: Call) {
    guard let entry = last[call.id], entry.state != .ended else { return }
    if case .ended(.endedHere) = call.status { return }
    person[call.id, default: []].insert(.end)
    continuation.yield(.choice(call.id, .failed))
  }

  private func claimAudio(hasVideo: Bool) {
    guard !claimsAudio else { return }
    claimsAudio = true
    continuation.yield(.claimAudio(hasVideo: hasVideo))
  }

  private func releaseAudio() {
    guard claimsAudio else { return }
    claimsAudio = false
    continuation.yield(.releaseAudio)
  }
}
