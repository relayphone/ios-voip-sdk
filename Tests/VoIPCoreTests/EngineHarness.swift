import Foundation
import Observation
import Testing
import VoIPTesting

@testable import VoIPCore

/// The engine tests. They run one at a time because a process runs at most one client.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct EngineTests {}

let bob: Party = {
  do {
    return try Party(handle: Handle(kind: .generic, value: "bob"), displayName: "Bob")
  } catch {
    preconditionFailure("The fixture handle is valid: \(error)")
  }
}()

let ringingCall = IncomingCall(id: callID, parties: [alice])
let e1 = EventID(rawValue: "event-1")
let e2 = EventID(rawValue: "event-2")
let e3 = EventID(rawValue: "event-3")

func incoming(_ id: CallID, _ presentation: PresentationPolicy.Presentation) -> IncomingCall {
  IncomingCall(
    id: id, parties: [alice], presentationPolicy: PresentationPolicy(incoming: presentation))
}

/// Runs a closure on ``VoIPActor`` in one job.
@VoIPActor
func onVoIPActor<Result: Sendable>(_ body: @VoIPActor () -> Result) -> Result {
  body()
}

/// An event reduced to what the engine tests compare.
enum Seen: Hashable, Sendable, CustomTestStringConvertible {
  case presented(CallID)
  case previewStarted(CallID, PreviewReason)
  case startRequested(CallID)
  case joinRequested(CallID)
  case performed(Action, CallStatus)
  case audioActivated
  case audioDeactivated
  case audioInterrupted(AudioInterruptionReason)
  case mediaServicesReset
  case ended(CallID, EndReason)

  init(_ event: CallEvent) {
    switch event {
    case .presented(let call): self = .presented(call.id)
    case .previewStarted(let call):
      guard case .previewing(let reason) = call.status else {
        preconditionFailure("A started preview has a preview status")
      }
      self = .previewStarted(call.id, reason)
    case .startRequested(let call): self = .startRequested(call.id)
    case .joinRequested(let call): self = .joinRequested(call.id)
    case .performed(let action, let call): self = .performed(action, call.status)
    case .audioActivated: self = .audioActivated
    case .audioDeactivated: self = .audioDeactivated
    case .audioInterrupted(let reason): self = .audioInterrupted(reason)
    case .mediaServicesReset: self = .mediaServicesReset
    case .ended(let call):
      guard case .ended(let reason) = call.status else {
        preconditionFailure("An ended call has an ended status")
      }
      self = .ended(call.id, reason)
    }
  }

  var testDescription: String { "\(self)".replacing("VoIPCore.", with: "") }
}

/// A report or an end the engine sent the calling framework, with throwaway calls told apart.
enum Reported: Hashable, Sendable {
  case report(CallID)
  case throwaway(parties: [Party])
  case ended(CallID, EndReason)
  case throwawayEnded(EndReason)
  case other(FakeCallingFramework.Record)

  /// Classifies records. A report of a call that isn't one of `known` is a throwaway.
  static func classify(
    _ records: some Sequence<FakeCallingFramework.Record>,
    known: Set<CallID> = [callID, otherCallID]
  ) -> [Reported] {
    var throwaways: Set<CallID> = []
    return records.map { record in
      switch record {
      case .reportIncoming(let call) where known.contains(call.id):
        return .report(call.id)
      case .reportIncoming(let call):
        throwaways.insert(call.id)
        return .throwaway(parties: call.parties)
      case .reportEnded(let id, let reason) where throwaways.contains(id):
        return .throwawayEnded(reason)
      case .reportEnded(let id, let reason):
        return .ended(id, reason)
      default:
        return .other(record)
      }
    }
  }
}

/// A client running on the fakes and a test clock.
@MainActor
final class Harness {
  let framework = FakeCallingFramework()
  let media = FakeMedia()
  let push: FakePushSource
  let audio = FakeAudioSession()
  let clock = TestClock()
  let client: VoIPClient
  private var iterator: AsyncStream<CallEvent>.Iterator?
  private var markers = 0

  /// Starts the client.
  ///
  /// - Parameters:
  ///   - configuration: The client's configuration.
  ///   - subscribe: Whether to subscribe to events as soon as the client starts.
  ///   - pending: VoIP pushes that arrive before the client attaches, as on a cold launch.
  ///   - observers: The client's observers.
  init(
    configuration: VoIPConfiguration = VoIPConfiguration(), subscribe: Bool = true,
    pending: [VoIPPush] = [], observers: [any CallObserver] = []
  ) throws {
    push = FakePushSource(pending: pending)
    client = try VoIPClient.start(
      framework: framework, media: media, push: push, audio: audio, observers: observers,
      configuration: configuration, clock: clock)
    if subscribe { self.subscribe() }
  }

  /// Subscribes to events from now on.
  func subscribe() {
    iterator = client.events().makeAsyncIterator()
  }

  /// The next event.
  func next() async throws -> Seen {
    var iterator = try #require(iterator, "The harness subscribes before reading events")
    let event = await iterator.next(isolation: #isolation)
    self.iterator = iterator
    return Seen(try #require(event, "The event stream doesn't finish"))
  }

  /// The next events.
  func next(_ count: Int) async throws -> [Seen] {
    var events: [Seen] = []
    for _ in 0..<count { events.append(try await next()) }
    return events
  }

  /// Expects that no event is waiting, by sending one that is known and reading it next.
  ///
  /// It then waits until the client's ``VoIPClient/calls`` include the call it sent, so that a
  /// test can read the client's state afterwards: the client applies the engine's state in a task
  /// of its own, which may not have run when the test reads an event.
  func expectNoEvents(sourceLocation: SourceLocation = #_sourceLocation) async throws {
    markers += 1
    let marker = CallID(rawValue: "marker-\(markers)")
    _ = await client.report(incoming(marker, .preview))
    #expect(try await next() == .previewStarted(marker, .policy), sourceLocation: sourceLocation)
    await until { client in client.calls.contains { $0.id == marker } }
  }

  /// Everything the engine asked of the calling framework.
  var records: [FakeCallingFramework.Record] {
    get async { await framework.records }
  }

  /// The reports and ends the engine sent the calling framework, after the first `count` records.
  func reported(after count: Int = 0) async -> [Reported] {
    Reported.classify(await records.dropFirst(count))
  }

  /// Delivers a VoIP push.
  func deliver(_ push: VoIPPush, mustReport: Bool = true) async {
    await self.push.deliver(push, mustReport: mustReport)
  }

  /// Delivers a VoIP push for an incoming call that rings, and reads its event.
  func ring(_ call: IncomingCall = ringingCall, eventID: EventID = e1) async throws {
    await deliver(.incoming(call, eventID: eventID))
    #expect(try await next() == .presented(call.id))
  }

  /// Answers a ringing call from the system's call screen, waits for the answer to complete,
  /// and returns the action's identifier.
  @discardableResult
  func answer(_ id: CallID = callID) async throws -> ActionID {
    let action = await framework.perform(.answer(id))
    #expect(try await next() == .performed(.answer(id), .connecting))
    return action
  }

  /// Rings, answers and connects a call.
  func connect(_ id: CallID = callID) async throws {
    try await ring(IncomingCall(id: id, parties: [alice]), eventID: EventID(rawValue: id.rawValue))
    try await answer(id)
    await framework.send(.audioActivated)
    #expect(try await next() == .audioActivated)
    await client.receive(.connected, for: id, eventID: EventID(rawValue: "\(id.rawValue)-up"))
  }

  /// The identifier of the last action the fake asked the engine to perform.
  func lastActionID() async throws -> ActionID {
    let events = await framework.sentEvents
    let ids = events.compactMap { event -> ActionID? in
      if case .perform(let id, _) = event { id } else { nil }
    }
    return try #require(ids.last)
  }

  /// Waits until the client's observable state satisfies a condition.
  func until(_ condition: @escaping @MainActor @Sendable (VoIPClient) -> Bool) async {
    let observations = Observations { @MainActor [weak client] in client.map(condition) ?? true }
    for await satisfied in observations where satisfied { return }
  }
}
