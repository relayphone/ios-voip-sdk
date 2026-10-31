#if os(iOS) && targetEnvironment(simulator)
  import CKSimProtocol
  import Foundation
  import Testing
  @preconcurrency import LiveCommunicationKit

  /// One LiveCommunicationKit app on the runtime, with the system's controls and the journal
  /// entries since the app started.
  @MainActor
  struct LCKSession {
    let runtime: Runtime
    let app: LCKApp
    /// The journal entries before the app started.
    let cursor: Int

    init(
      groups: Int = 2, perGroup: Int = 1,
      capabilities: Conversation.Capabilities = [.pausing, .merging, .unmerging]
    ) async throws {
      runtime = try Runtime.shared()
      try await runtime.clearSettings()
      cursor = try runtime.cursor()
      app = LCKApp(groups: groups, perGroup: perGroup, capabilities: capabilities)
      let created = try await runtime.entry("the conversation manager's provider", after: cursor) {
        $0.event == "provider.created"
      }
      #expect(
        try runtime.entries(after: cursor).count { $0.event == "provider.created" } == 1,
        "The app creates only the conversation manager's provider")
      _ = created
    }

    /// The journal entries since the app started.
    func entries(after index: Int? = nil) throws -> [Entry] {
      try runtime.entries(after: index ?? cursor)
    }

    /// The app's callback of `kind` (`perform`, `settled`, `changed` and so on) that matches,
    /// once it appears.
    @discardableResult
    func callback(
      _ kind: String, after index: Int? = nil, limit: Duration = Runtime.limit,
      sourceLocation: SourceLocation = #_sourceLocation,
      where matches: (Entry) -> Bool = { _ in true }
    ) async throws -> Entry {
      try await runtime.entry(
        "the app's \(kind) callback", after: index ?? cursor, limit: limit,
        sourceLocation: sourceLocation
      ) { $0.event == "lck.fixture." + kind && matches($0) }
    }

    /// Performs a system control on the named conversations.
    @discardableResult
    func system(_ control: (LCKApp) -> ControlRequest.CallControl) async throws -> [UUID] {
      try await runtime.perform(control(app))
    }

    /// Waits until the named conversations are in the given states.
    func expect(
      _ states: KeyValuePairs<String, String>, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
      let description = states.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
      try await runtime.until(description, sourceLocation: sourceLocation) {
        states.allSatisfy { app.state($0.key) == $0.value } ? true : nil
      }
    }

    /// The choices the runtime offers on the system's call screen for a ringing conversation.
    func choices(_ name: String) async throws -> Set<String> {
      let call = try #require(
        try await runtime.status().calls.first { $0.state.uuid == app.id(name) })
      guard case .livecommunicationkit(let choices) = call.relationship else {
        throw RuntimeTestError("\(name) isn't a LiveCommunicationKit call")
      }
      return Set(choices.map(\.rawValue))
    }

    /// Reports A, answers it from the system's call screen, waits for its audio, then reports B.
    func pair() async throws {
      try await app.reportIncoming("A")
      try await system { .answer($0.id("A")) }
      try await expect(["A": "joined"])
      try await callback("didActivate")
      try await app.reportIncoming("B")
    }

    /// Performs a system call-waiting control, such as Hold & Accept, and checks that the app
    /// received its actions together in one transaction.
    func composite(
      _ control: String = "hold-and-accept", call: String = "B", active: String = "A",
      held: String? = nil, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> Set<String> {
      let start = try runtime.cursor()
      let (accepted, current) = (app.id(call), app.id(active))
      let operation: ControlRequest.CallControl =
        switch control {
        case "hold-and-accept": .holdAndAccept(accepted, active: current)
        case "end-and-accept": .endAndAccept(accepted, active: current)
        default: .endHeldAndAccept(accepted, active: current, held: app.id(held ?? "A"))
        }
      let ids = try await runtime.perform(operation)
      let actions = Set(ids.map(\.uuidString))
      let performed = try await runtime.until("the app to receive every action") {
        let rows = try entries(after: start).filter {
          $0.event == "lck.fixture.perform" && actions.contains($0.actionID ?? "")
        }
        return rows.count == actions.count ? rows : nil
      }
      var expected: Set<[String]> = [
        ["Join", accepted.uuidString],
        [control == "end-and-accept" ? "End" : "Pause", current.uuidString],
      ]
      if let held { expected.insert(["End", app.id(held).uuidString]) }
      #expect(
        Set(performed.map { [$0.kind ?? "", $0.callUUID ?? ""] }) == expected,
        sourceLocation: sourceLocation)
      #expect(
        performed.map(\.time) == performed.map(\.time).sorted(), sourceLocation: sourceLocation)
      let issued = try entries(after: start).filter {
        $0.event == "action.deadline" && actions.contains($0.actionID ?? "")
      }
      #expect(issued.count == actions.count, sourceLocation: sourceLocation)
      #expect(Set(issued.compactMap(\.transactionID)).count == 1, "One system transaction")
      #expect(issued.allSatisfy { $0.apiKind == "livecommunicationkit" })
      return actions
    }

    /// Checks that the accepted conversation joined only after every action settled.
    func expectJoinedAfterEveryAction(
      _ actions: Set<String>, accepted: String = "B",
      sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
      let rows = try entries()
      let terminal = rows.filter {
        ["lck.fixture.settled", "lck.fixture.timedOut"].contains($0.event)
          && actions.contains($0.actionID ?? "")
      }
      #expect(Set(terminal.compactMap(\.actionID)) == actions, sourceLocation: sourceLocation)
      let joined = try #require(
        rows.first {
          $0.event == "lck.fixture.changed" && $0.callUUID == app.id(accepted).uuidString
            && $0.state == "joined"
        }, sourceLocation: sourceLocation)
      #expect(
        joined.sequence > terminal.map(\.sequence).max() ?? .max, sourceLocation: sourceLocation)
    }

    /// Checks that the app's callbacks arrived on the main queue, then ends the app's calls.
    func finish() async throws {
      #expect(
        try entries().filter { $0.event.hasPrefix("lck.fixture.") }.allSatisfy { $0.main == true })
      for kind in ["Join", "Start", "Pause", "End", "Merge", "Unmerge"] {
        app.settle(kind, .immediate)
      }
      try await runtime.clearSettings()
      try await runtime.end(app.ids.values)
    }
  }
#endif
