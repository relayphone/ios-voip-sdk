#if os(iOS) && targetEnvironment(simulator)
  import CKSimProtocol
  import Foundation
  import Testing
  import VoIPCore
  import VoIPLiveCommunicationKit
  import VoIPPushKit
  import VoIPSimulator
  import VoIPTesting

  /// An app as a journey runs it: the client with the LiveCommunicationKit adapter and the
  /// PushKit source on the simulator runtime, and media that records what the SDK asks of it.
  @MainActor
  final class App {
    /// How long a journey waits for something the simulated system does in real time.
    static let limit = Duration.seconds(10)

    let client: VoIPClient
    let media = FakeMedia()
    let system: SimulatedSystem
    private var events: [CallEvent] = []
    private var cursor = 0
    private var listener: Task<Void, Never>?

    /// Starts the app on the simulator runtime.
    ///
    /// - Parameters:
    ///   - audio: The app's audio session. Without one, the app configures it itself.
    ///   - observers: Objects that follow the client's calls from the moment it starts.
    ///   - configuration: How the SDK presents and controls calls.
    ///   - listening: Whether the app listens for call events from the start. An app whose code
    ///     is still loading starts listening later, with ``listen()``.
    ///   - launch: What the system does before the app starts the client, such as
    ///     delivering the VoIP push that launched it.
    init(
      audio: (any AudioSession)? = nil,
      observers: [any CallObserver] = [],
      configuration: VoIPConfiguration = VoIPConfiguration(),
      listening: Bool = true,
      launch: (SimulatedSystem) async throws -> Void = { _ in }
    ) async throws {
      try #require(VoIPSimulator.activate(), "The simulator runtime didn't activate")
      system = try SimulatedSystem()
      try await launch(system)
      client = try VoIPClient.start(
        framework: LiveCommunicationKitAdapter(), media: media, push: PushKitSource(),
        audio: audio, observers: observers, configuration: configuration)
      if listening { listen() }
    }

    /// Starts listening for call events. Events from before are lost, as they are for an app.
    func listen() {
      guard listener == nil else { return }
      let stream = client.events()
      listener = Task { [weak self] in
        for await event in stream { self?.events.append(event) }
      }
    }

    /// Stops listening, so that the client is released when the journey ends.
    func stop() {
      listener?.cancel()
    }

    /// Waits for the next events and checks them against what the journey expects.
    func expect(
      _ expected: [Seen], sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
      try await until("\(expected) to happen") {
        events.count - cursor >= expected.count
      }
      let seen = events[cursor..<cursor + expected.count].map(Seen.init)
      cursor += expected.count
      #expect(seen == expected, sourceLocation: sourceLocation)
    }

    /// Waits for the next events and checks them against sequences that happen independently,
    /// such as the calls' events and the system's audio activation, which the simulated system
    /// interleaves in real time. Each sequence keeps its own order.
    func expect(
      interleaving sequences: [Seen]..., sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
      let count = sequences.map(\.count).reduce(0, +)
      try await until("\(sequences) to happen") {
        events.count - cursor >= count
      }
      let seen = events[cursor..<cursor + count].map(Seen.init)
      cursor += count
      for sequence in sequences {
        #expect(seen.filter { sequence.contains($0) } == sequence, sourceLocation: sourceLocation)
      }
    }

    /// Checks that nothing else happened to calls.
    func expectNoMoreEvents(sourceLocation: SourceLocation = #_sourceLocation) {
      #expect(events[cursor...].map(Seen.init) == [], sourceLocation: sourceLocation)
    }

    /// The client's call.
    func call(_ id: CallID) -> Call? {
      client.calls.first { $0.id == id }
    }

    /// Waits until a condition holds, checking it as the simulated system moves on in real time.
    func until(_ description: String, _ condition: () async throws -> Bool) async throws {
      let deadline = ContinuousClock.now + Self.limit
      while try await !condition() {
        guard ContinuousClock.now < deadline else {
          throw JourneyError("Timed out waiting for \(description)")
        }
        try await Task.sleep(for: .milliseconds(20))
      }
    }

    /// Checks that the system finished the journey's pushes, and that the app met PushKit's
    /// reporting rules for each.
    func expectPushesFinished(
      _ pushIDs: [UUID], sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
      let ids = Set(pushIDs.map(\.uuidString))
      try await until("the pushes to finish") {
        let completed = try await system.journal().filter {
          $0.event == "push.completed" && ids.contains($0.pushID ?? "")
        }
        return completed.count == ids.count
      }
      let violations = try await system.journal().filter {
        $0.event.hasPrefix("diagnostic.push") && ids.contains($0.pushID ?? "")
      }
      #expect(violations.map { $0.reason ?? $0.event } == [], sourceLocation: sourceLocation)
    }
  }

  /// A call event reduced to what journeys compare.
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

  extension SimulatedSystem {
    /// Delivers a VoIP push for an incoming call, in the SDK's default format.
    @discardableResult
    func pushIncomingCall(
      _ id: CallID, from number: String = "+14155550123",
      metadata: [String: PushPayload.Value] = [:]
    ) async throws -> UUID {
      try await push([
        "aps": .object([:]),
        "incomingCall": .object([
          "eventId": .string("invite-\(id.rawValue)"),
          "serverCallId": .string(id.rawValue),
          "caller": .object([
            "handleType": .string("phone"), "value": .string(number),
            "displayName": .string("Alice"),
          ]),
          "metadata": .object(metadata),
        ]),
      ])
    }

    /// Delivers a VoIP push that tells the app the call ended elsewhere, in the SDK's default
    /// format.
    @discardableResult
    func pushCallEnded(_ id: CallID, reason: String) async throws -> UUID {
      let body =
        #"{"eventId":"ended-\#(id.rawValue)","serverCallId":"\#(id.rawValue)","reason":"\#(reason)"}"#
      return try await push([
        "aps": .object([:]), "messageType": .string("callEnded"), "callEnded": .string(body),
      ])
    }
  }

  /// A new call ID, so that no journey sees another's calls.
  func newCallID(_ name: String) -> CallID {
    CallID(rawValue: "\(name)-\(UUID().uuidString.prefix(8))")
  }
#endif
