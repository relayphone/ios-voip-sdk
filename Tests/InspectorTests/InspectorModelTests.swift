import Foundation
import Testing

@testable import CKSimInspector

/// The Inspector's model: it follows the journal and changes nothing until the journal confirms a
/// control.
@MainActor
struct InspectorModelTests {
  private static let active = "00000001-1111-4111-8111-111111111111"
  private static let held = "00000002-1111-4111-8111-111111111111"
  private static let waiting = "00000003-1111-4111-8111-111111111111"

  private static func transaction(_ index: Int) -> String {
    String(format: "30000000-0000-4000-8000-%012X", index)
  }

  /// The actions the scripted runtime delivers for the control at this one-based index.
  private static func actions(_ index: Int) -> [[String: Any]] {
    let definitions: [(String, String, [String: Any])] =
      index == 5
      ? [(active, "hold", ["held": true]), (held, "end", [:]), (waiting, "answer", [:])]
      : [
        (
          active, index <= 2 ? "hold" : "group",
          index <= 2 ? ["held": index == 1] : ["groupTargetUUID": index == 3 ? waiting : ""]
        )
      ]
    return definitions.enumerated().map { offset, definition in
      var action: [String: Any] = [
        "actionID": String(format: "20000000-0000-4000-8000-%012X", index * 10 + offset),
        "callUUID": definition.0, "kind": definition.1, "transactionID": transaction(index),
        "origin": "system", "provider": "p1", "apiKind": "livecommunicationkit",
      ]
      action.merge(definition.2) { _, new in new }
      return action
    }
  }

  @Test func liveCommunicationKitControlsWaitForTheirActions() async throws {
    let bridge = ScriptedBridge()
    var calls: [String: [String: Any]] = [:]
    for id in [Self.active, Self.held, Self.waiting] {
      calls[id] = [
        "uuid": id, "connected": id != Self.waiting, "ringing": id == Self.waiting,
        "ended": false, "held": id == Self.held, "capabilities": [String](),
        "apiKind": "livecommunicationkit",
        "availableSystemChoices": id == Self.waiting ? ["end-held-and-accept"] : [],
      ]
    }
    bridge.append(
      "provider.created", ["provider": "p1", "maximumCallGroups": 2, "maximumCallsPerCallGroup": 1])
    bridge.append("provider.apiKind", ["provider": "p1", "apiKind": "livecommunicationkit"])
    for id in [Self.active, Self.held, Self.waiting] { bridge.append("call.changed", calls[id]!) }
    bridge.respond = { _, index in
      [
        "result": [
          "actionIDs": Self.actions(index).map { ($0["actionID"] as! String).lowercased() },
          "transactionID": Self.transaction(index),
        ]
      ]
    }
    let (model, task) = following(bridge)
    defer { task.cancel() }
    try await wait("three calls") { model.online && model.conversations.count == 3 }
    let configuration = try #require(model.providerConfigurations.first { $0.provider == "p1" })
    #expect(configuration.apiKind == "livecommunicationkit")
    #expect(configuration.maximumCallGroups == 2 && configuration.maximumCallsPerCallGroup == 1)
    let ringing = try #require(model.conversations[Self.waiting])
    #expect(ringing.ringing == true && ringing.capabilities == [])
    #expect(ringing.availableSystemChoices == ["end-held-and-accept"])

    for index in 1...5 {
      let active = try #require(model.conversations[Self.active])
      let held = try #require(model.conversations[Self.held])
      let waiting = try #require(model.conversations[Self.waiting])
      let states = model.conversations.mapValues(\.status)
      switch index {
      case 1: model.send("hold", call: active, held: true, applicationRequest: true)
      case 2: model.send("hold", call: active, held: false, applicationRequest: true)
      case 3: model.send("merge", call: active, groupTarget: waiting, applicationRequest: true)
      case 4: model.send("unmerge", call: active, applicationRequest: true)
      default: model.send("end-held-and-accept", call: waiting, active: active, heldCall: held)
      }
      #expect(model.busy)
      try await wait("the command") {
        model.timeline.contains {
          $0.event == "test.commandAccepted" && $0.requestID == ScriptedBridge.responseID(index)
        }
      }
      #expect(
        model.busy && model.conversations.mapValues(\.status) == states, "Nothing changes yet")

      let constituents = Self.actions(index)
      let classes = [
        "hold": "CXSetHeldCallAction", "end": "CXEndCallAction", "answer": "CXAnswerCallAction",
        "group": "CXSetGroupCallAction",
      ]
      bridge.append(
        "transaction.delivered",
        [
          "transactionID": Self.transaction(index), "provider": "p1", "origin": "system",
          "actionIDs": constituents.map { $0["actionID"]! },
          "callUUIDs": constituents.map { $0["callUUID"]! },
          "kinds": constituents.map { classes[$0["kind"] as! String]! },
          "parameters": constituents.map {
            $0.filter { ["held", "groupTargetUUID"].contains($0.key) }
          },
        ])
      for action in constituents { bridge.append("action.deadline", action) }
      try await wait("the actions to be delivered") { !model.busy && !model.pending.isEmpty }
      #expect(model.commandError == nil)
      if index == 3 { #expect(model.isPending(waiting), "A ringing merge target is pending") }
      if index == 5 {
        #expect(model.isPending(active) && model.isPending(held) && model.isPending(waiting))
      }

      if index <= 2 { calls[Self.active]?["held"] = index == 1 }
      if index == 5 {
        calls[Self.held]?["ended"] = true
        calls[Self.active]?["held"] = true
        calls[Self.waiting]?.merge(
          ["connected": true, "ringing": false, "availableSystemChoices": [String]()]
        ) { _, new in new }
      }
      for id in [Self.active, Self.held, Self.waiting] { bridge.append("call.changed", calls[id]!) }
      for action in constituents {
        bridge.append("action.settled", action.merging(["fulfilled": true]) { _, new in new })
      }
      try await wait("the actions to settle") { model.pending.isEmpty }
      if index <= 2 { #expect(model.conversations[Self.active]?.held == (index == 1)) }
    }
    #expect(model.conversations[Self.active]?.held == true)
    #expect(model.conversations[Self.held]?.ended == true)
    #expect(model.conversations[Self.waiting]?.connected == true && model.incoming == nil)
    #expect(
      bridge.commands == [
        [
          "operation": "hold", "callUUID": Self.active, "held": "true",
          "applicationRequest": "true",
        ],
        [
          "operation": "hold", "callUUID": Self.active, "held": "false",
          "applicationRequest": "true",
        ],
        [
          "operation": "merge", "callUUID": Self.active, "groupWithCallUUID": Self.waiting,
          "applicationRequest": "true",
        ],
        ["operation": "unmerge", "callUUID": Self.active, "applicationRequest": "true"],
        [
          "operation": "end-held-and-accept", "callUUID": Self.waiting,
          "activeCallUUID": Self.active, "heldCallUUID": Self.held,
        ],
      ])

    // A new transaction stays pending while older ones leave the model's cache.
    for number in 0..<100 {
      let id = String(format: "%08X-1111-4111-8111-111111111111", number + 100)
      bridge.append(
        "transaction.delivered",
        [
          "transactionID": "old-\(number)", "actionIDs": ["old-action-\(number)"],
          "callUUIDs": [id],
        ])
      bridge.append(
        "action.deadline",
        ["actionID": "old-action-\(number)", "callUUID": id, "transactionID": "old-\(number)"])
    }
    bridge.append(
      "transaction.delivered",
      [
        "transactionID": "overflow-new", "actionIDs": ["overflow-first", "overflow-second"],
        "callUUIDs": [Self.active, Self.waiting],
      ])
    for (action, call) in [("overflow-first", Self.active), ("overflow-second", Self.waiting)] {
      bridge.append(
        "action.deadline", ["actionID": action, "callUUID": call, "transactionID": "overflow-new"])
    }
    bridge.append(
      "action.settled",
      [
        "actionID": "overflow-first", "callUUID": Self.active, "transactionID": "overflow-new",
        "fulfilled": true,
      ])
    try await wait("the overflow") {
      model.timeline.contains { $0.event == "action.settled" && $0.actionID == "overflow-first" }
    }
    #expect(model.pending["overflow-first"] == nil && model.pending["overflow-second"] != nil)
    let active = try #require(model.conversations[Self.active])
    let waiting = try #require(model.conversations[Self.waiting])
    #expect(model.isPending(active) && model.isPending(waiting), "The new transaction stays")
  }

  enum Setting: String, CaseIterable { case filter, faults }

  /// How the scripted runtime answers and confirms a setting.
  enum Script: String, CaseIterable {
    /// The runtime confirms the setting in its journal with the request's identifier.
    case confirmed
    /// The journal confirms the same kind of setting for another request.
    case otherRequest
    /// The journal never confirms it.
    case unconfirmed
    case otherValue, otherKind, actionWithTheRequestsID
    case responseOfAnotherKind, responseWithAnotherValue, responseFromAnotherRun, rejection
  }

  private static func filterState(_ reason: String) -> [String: Any] {
    [
      "reason": reason, "code": reason == "none" ? 0 : 3,
      "verification": reason == "none" ? "not-applicable" : "verified",
    ]
  }

  @Test(arguments: Setting.allCases, Script.allCases)
  func aSettingChangesOnlyWhenTheJournalConfirmsIt(setting: Setting, script: Script) async throws {
    let faults = setting == .faults
    let bridge = ScriptedBridge()
    bridge.respond = { command, _ in
      var result: [String: Any] =
        faults
        ? ["configured": true, "incomingErrorCode": Int(command["incomingErrorCode"] ?? "") ?? -1]
        : ["incomingFilter": Self.filterState(command["reason"] ?? "")]
      switch script {
      case .responseOfAnotherKind: result = ["events": "unrelated result"]
      case .responseWithAnotherValue:
        result =
          faults
          ? ["configured": true, "incomingErrorCode": 0]
          : ["incomingFilter": Self.filterState("none")]
      case .responseFromAnotherRun: return ["result": result, "runID": "another-run"]
      case .rejection: return ["success": false, "error": "runtime rejection message"]
      default: break
      }
      return ["result": result]
    }
    let (model, task) = following(bridge)
    defer { task.cancel() }
    try await wait("the model to connect") { model.online }
    let values = script == .confirmed ? [true, false] : [true]
    var priorFilter = InspectorIncomingFilter.none
    var priorCode = 0
    for (offset, on) in values.enumerated() {
      let reason: InspectorIncomingFilter = on ? .doNotDisturb : .none
      let code = on ? 4 : 0
      let requestID = ScriptedBridge.responseID(offset + 1)
      let started = ContinuousClock.now
      if faults {
        model.configureIncomingError(code)
      } else {
        model.configureIncomingFilter(reason)
      }
      #expect(model.busy)
      try await wait("the command") {
        model.timeline.contains { $0.event == "test.commandAccepted" && $0.requestID == requestID }
      }
      if script.rawValue.hasPrefix("response") || script == .rejection {
        try await wait("the response to fail") { !model.busy }
        #expect(model.commandError != nil, "A response that doesn't match can't confirm it")
        #expect(model.incomingFilter == priorFilter && model.incomingErrorCode == priorCode)
        if script == .rejection { #expect(model.commandError == "runtime rejection message") }
        continue
      }
      #expect(model.busy && model.commandError == nil)
      #expect(model.incomingFilter == priorFilter && model.incomingErrorCode == priorCode)

      let confirmation: [String: Any] =
        script == .otherRequest
        ? ["requestID": "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF"] : ["requestID": requestID]
      switch script {
      case .unconfirmed: break
      case .actionWithTheRequestsID: bridge.append("action.deadline", ["actionID": requestID])
      case .otherKind:
        if faults {
          bridge.append(
            "incomingFilter.configured", confirmation.merging(Self.filterState("none")) { $1 })
        } else {
          bridge.append("faults.configured", confirmation.merging(["incomingErrorCode": 0]) { $1 })
        }
      default:
        let other = script == .otherValue
        if faults {
          bridge.append(
            "faults.configured",
            confirmation.merging(["incomingErrorCode": other ? 0 : code]) { $1 })
        } else {
          bridge.append(
            "incomingFilter.configured",
            confirmation.merging(Self.filterState(other ? "none" : reason.rawValue)) { $1 })
        }
      }
      if script == .otherRequest {
        try await wait("the other request's confirmation") {
          model.timeline.contains {
            $0.event == (faults ? "faults.configured" : "incomingFilter.configured")
          }
        }
        #expect(model.busy, "Another request's confirmation doesn't confirm this one")
        #expect(model.incomingFilter == (faults ? priorFilter : reason))
        #expect(model.incomingErrorCode == (faults ? code : priorCode))
      }
      try await wait("the setting to finish") { !model.busy }
      if script == .confirmed {
        #expect(model.commandError == nil)
        #expect(model.incomingFilter == (faults ? priorFilter : reason))
        #expect(model.incomingErrorCode == (faults ? code : priorCode))
      } else {
        #expect(started.duration(to: .now) >= .milliseconds(2900), "It waits for the confirmation")
        #expect(model.commandError?.contains("journal confirmation has not arrived") == true)
        #expect(model.incomingFilter == (!faults && script == .otherRequest ? reason : priorFilter))
        #expect(model.incomingErrorCode == (faults && script == .otherRequest ? code : priorCode))
      }
      if faults { priorCode = code } else { priorFilter = reason }
    }
    #expect(
      bridge.commands.map { $0["operation"] }
        == Array(repeating: faults ? "faults" : "incoming-filter", count: values.count))
  }
}
