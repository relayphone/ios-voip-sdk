import Foundation
import Testing

@testable import CKSimInspector

/// The Inspector's comparison of the simulator's timings with the device measurements.
struct TimingReferenceTests {
  private func metric(_ name: String, _ events: [RuntimeEvent]) throws -> RuntimeTimingReadout {
    try #require(RuntimeTimingReferences.project(events).first { $0.id == name })
  }

  @Test func everyReferenceStartsWithoutAMeasurement() throws {
    let empty = RuntimeTimingReferences.project([])
    #expect(empty.map(\.id) == ["pushReport", "answerAudio", "muteEcho", "unreportedPush"])
    #expect(
      empty.allSatisfy { $0.actualMS == nil && $0.startSequence == nil && $0.endSequence == nil })
    #expect(
      empty.map(\.deviceValue) == ["≈190 ms", "≈236 ms", "8–17 ms after fulfillment", "≈4.4 s"])
    #expect(empty.allSatisfy { $0.deviceProvenance.contains("LCK · iPhone 13 · iOS 27.0") })
    let decoded = try JSONDecoder().decode(
      [RuntimeTimingReadout].self, from: JSONEncoder().encode(empty))
    #expect(decoded.map(\.deviceValue) == empty.map(\.deviceValue))
  }

  @Test func referencesCiteDocumentsInTheRepository() {
    let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let sources = Set(RuntimeTimingReferences.project([]).map(\.sourcePath)).union([
      InspectorLCKProjection.sourcePath
    ])
    for source in sources {
      #expect(FileManager.default.fileExists(atPath: root.appending(path: source).path()), "\(source)")
    }
  }

  @Test func measuresEachInterval() throws {
    let pushed = try event(1, 100, "push.received", ["pushID": "p1", "mustReport": true])
    let reported = try event(2, 290, "report.completed", ["pushID": "p1", "error": 0])
    let report = try metric("pushReport", [pushed, reported])
    #expect(report.actualMS == 190 && report.startSequence == 1 && report.endSequence == 2)

    let answer = try event(
      3, 300, "action.deadline",
      [
        "kind": "answer", "callUUID": "c1", "actionID": "a1", "apiKind": "callkit",
        "provider": "provider1",
      ])
    let answered = try event(
      4, 425, "action.settled",
      [
        "kind": "answer", "callUUID": "c1", "actionID": "a1", "apiKind": "callkit",
        "fulfilled": true,
      ])
    let audio = try event(5, 536, "audio.activated")
    let activation = try metric("answerAudio", [answer, answered, audio])
    #expect(
      activation.actualMS == 236 && activation.startSequence == 3 && activation.endSequence == 5)
    #expect(activation.actualLabel == "Simulator · CallKit answer delivered → audio.activated")
    let join = try event(
      3, 300, "action.deadline",
      [
        "kind": "answer", "callUUID": "c1", "actionID": "a1", "apiKind": "livecommunicationkit",
        "provider": "provider1",
      ])
    let joined = try event(
      4, 425, "action.settled",
      [
        "kind": "answer", "callUUID": "c1", "actionID": "a1", "apiKind": "livecommunicationkit",
        "fulfilled": true,
      ])
    #expect(
      try metric("answerAudio", [join, joined, audio]).actualLabel
        == "Simulator · LCK join delivered → audio.activated")

    let fulfilled = try event(
      1, 600, "action.settled",
      [
        "kind": "mute", "origin": "application", "fulfilled": true, "muted": false,
        "callUUID": "c1", "actionID": "m1", "transactionID": "t1",
        "apiKind": "livecommunicationkit", "provider": "provider1",
      ])
    let echo = try event(
      2, 615, "action.deadline",
      [
        "kind": "mute", "origin": "muteEcho", "muted": false, "callUUID": "c1", "actionID": "m2",
        "transactionID": "t2", "apiKind": "livecommunicationkit", "provider": "provider1",
      ])
    let mute = try metric("muteEcho", [fulfilled, echo])
    #expect(mute.actualMS == 15 && mute.startSequence == 1 && mute.endSequence == 2)

    let expired = try event(2, 4500, "diagnostic.pushReportExpired", ["pushID": "p1"])
    let deadline = try metric("unreportedPush", [pushed, expired])
    #expect(deadline.actualMS == 4400 && deadline.startSequence == 1 && deadline.endSequence == 2)
  }

  @Test(arguments: ["report.completed", "diagnostic.pushReportExpired"])
  func unrelatedOrMissingPushEventsMeasureNothing(name: String) throws {
    let id = name == "report.completed" ? "pushReport" : "unreportedPush"
    let pushed = try event(1, 100, "push.received", ["pushID": "p1", "mustReport": true])
    let unrelated: [(Double, [String: Any])] = [
      (290, ["pushID": "other"]), (90, ["pushID": "p1"]), (290, ["pushID": "p1", "runID": "other"]),
      (290, ["pushID": "p1", "pid": 999]),
    ]
    for (time, fields) in unrelated {
      #expect(try metric(id, [pushed, event(2, time, name, fields)]).actualMS == nil)
    }
    let completed = try event(2, 290, name, ["pushID": "p1"])
    #expect(try metric(id, [completed]).actualMS == nil, "An evicted start is unavailable")
    let missingIDs = try [event(1, 100, "push.received"), event(2, 290, name)]
    #expect(try metric(id, missingIDs).actualMS == nil)
  }

  @Test func pushIntervalsNeedAReportingObligationAndASuccessfulReport() throws {
    let pushed = try event(1, 100, "push.received", ["pushID": "p1", "mustReport": true])
    let optional = try event(1, 100, "push.received", ["pushID": "p1", "mustReport": false])
    let expired = try event(2, 4500, "diagnostic.pushReportExpired", ["pushID": "p1"])
    #expect(try metric("unreportedPush", [optional, expired]).actualMS == nil)
    let invalidTime = RuntimeEvent(
      schemaVersion: 1, sequence: 1, runID: "run", pid: 123, bundleID: "test.fixture",
      event: "push.received", t_ms: .nan, pushID: "p1")
    let report = try event(2, 290, "report.completed", ["pushID": "p1"])
    #expect(try metric("pushReport", [invalidTime, report]).actualMS == nil)
    let filtered = try event(2, 2170, "report.completed", ["pushID": "p1", "error": 3])
    #expect(
      try metric("pushReport", [pushed, filtered]).actualMS == nil,
      "A filtered report isn't compared with the successful device report")
    #expect(
      try metric("pushReport", [pushed, report]).actualMS == nil, "An unknown outcome is unavailable")
    let controlFailure = try event(3, 300, "control.completed", ["error": "Rejected command"])
    #expect(controlFailure.title == "control.completed", "String errors stay decodable")
  }

  @Test func muteEchoesNeedTheSameCallProviderAndValue() throws {
    let app: [String: Any] = [
      "kind": "mute", "origin": "application", "fulfilled": true, "muted": true, "callUUID": "c1",
      "actionID": "m1", "transactionID": "t1", "apiKind": "livecommunicationkit",
      "provider": "provider1",
    ]
    let fulfilled = try event(1, 600, "action.settled", app)
    let baseEcho: [String: Any] = [
      "kind": "mute", "origin": "muteEcho", "muted": true, "callUUID": "c1", "actionID": "m2",
      "transactionID": "t2", "apiKind": "livecommunicationkit", "provider": "provider1",
    ]
    let changes: [[String: Any]] = [
      ["muted": false], ["callUUID": "other"], ["apiKind": "callkit"], ["provider": "other"],
      ["origin": "system"], ["actionID": ""], ["transactionID": ""],
    ]
    for change in changes {
      let wrongEcho = try event(2, 615, "action.deadline", baseEcho.merging(change) { _, new in new })
      #expect(try metric("muteEcho", [fulfilled, wrongEcho]).actualMS == nil)
    }
    let pending = try event(1, 500, "action.deadline", app)
    let echo = try event(2, 615, "action.deadline", baseEcho)
    #expect(
      try metric("muteEcho", [pending, echo]).actualMS == nil,
      "Delivery without the app's fulfillment measures nothing")
    for provider in [nil, ""] as [String?] {
      var unidentifiedApp = app
      var unidentifiedEcho = baseEcho
      unidentifiedApp["provider"] = provider
      unidentifiedEcho["provider"] = provider
      let unidentified = try [
        event(1, 600, "action.settled", unidentifiedApp),
        event(2, 615, "action.deadline", unidentifiedEcho),
      ]
      #expect(
        try metric("muteEcho", unidentified).actualMS == nil,
        "Two unidentified providers aren't the same provider")
    }
  }

  @Test func onlyTheLatestAttemptIsMeasured() throws {
    let pushed = try event(1, 100, "push.received", ["pushID": "p1", "mustReport": true])
    let report = try event(2, 290, "report.completed", ["pushID": "p1"])
    let next = try event(3, 500, "push.received", ["pushID": "p2", "mustReport": true])
    #expect(try metric("pushReport", [pushed, report, next]).actualMS == nil)
    let answer: [String: Any] = [
      "kind": "answer", "callUUID": "c1", "actionID": "a1", "apiKind": "callkit",
    ]
    let delivered = try event(1, 100, "action.deadline", answer)
    let audio = try event(2, 336, "audio.activated")
    let newest = try event(
      3, 500, "action.deadline", answer.merging(["actionID": "a2"]) { _, new in new })
    #expect(try metric("answerAudio", [delivered, audio, newest]).actualMS == nil)
    let unknown = try event(
      3, 500, "action.deadline", answer.merging(["apiKind": "unknown"]) { _, new in new })
    let latestAudio = try event(4, 736, "audio.activated")
    #expect(try metric("answerAudio", [unknown, latestAudio]).actualMS == nil)

    let app: [String: Any] = [
      "kind": "mute", "origin": "application", "fulfilled": true, "muted": true, "callUUID": "c1",
      "apiKind": "callkit",
    ]
    let fulfilled = try event(1, 100, "action.settled", app)
    let echo = try event(
      2, 115, "action.deadline", app.merging(["origin": "muteEcho"]) { _, new in new })
    let failed = try event(
      3, 200, "action.settled", app.merging(["fulfilled": false]) { _, new in new })
    #expect(try metric("muteEcho", [fulfilled, echo, failed]).actualMS == nil)
  }

  @Test func anInvalidatedAnswerOwnsNoAudioActivation() throws {
    let delivered = try event(
      1, 100, "action.deadline",
      ["kind": "answer", "callUUID": "c1", "actionID": "a1", "apiKind": "callkit"])
    let audio = try event(4, 336, "audio.activated")
    #expect(
      try metric("answerAudio", [delivered, audio]).actualMS == nil,
      "A pending answer can't own the process's audio")
    let fulfilled = try event(
      2, 220, "action.settled",
      [
        "kind": "answer", "actionID": "a1", "callUUID": "c1", "apiKind": "callkit",
        "fulfilled": true,
      ])
    let blockers: [(String, [String: Any])] = [
      ("action.settled", ["actionID": "a1", "fulfilled": false]),
      ("action.expired", ["actionID": "a1"]), ("action.timeout", ["actionID": "a1"]),
      ("action.cancelled", ["actionID": "a1"]), ("call.changed", ["uuid": "c1", "ended": true]),
      ("provider.reset", [:]), ("provider.invalidated", [:]), ("audio.failed", [:]),
      ("fault.audioSuppressed", [:]), ("action.deadline", ["kind": "start"]),
      ("action.deadline", ["kind": "hold"]), ("action.deadline", ["kind": "end"]),
      ("action.settled", ["kind": "start", "fulfilled": true]),
      ("action.settled", ["kind": "hold", "fulfilled": true]),
      ("action.settled", ["kind": "end", "fulfilled": true]),
      (
        "action.settled",
        [
          "kind": "answer", "actionID": "older-answer", "callUUID": "c2", "apiKind": "callkit",
          "fulfilled": true,
        ]
      ),
      (
        "action.deadline",
        ["kind": "answer", "actionID": "other-answer", "callUUID": "c2", "apiKind": "callkit"]
      ),
      ("report.connected", [:]),
    ]
    for (name, fields) in blockers {
      let blocked = try event(3, 250, name, fields)
      #expect(
        try metric("answerAudio", [delivered, fulfilled, blocked, audio]).actualMS == nil,
        "\(name) leaves the activation ambiguous")
    }
    #expect(
      try metric("answerAudio", [delivered, fulfilled, audio]).actualMS == 236,
      "The interval starts at delivery, not fulfillment")
  }

  @Test func overlappingMuteEchoesAreAmbiguous() throws {
    func mute(_ sequence: Int, _ time: Double, _ id: String, echo: Bool = false) throws
      -> RuntimeEvent
    {
      try event(
        sequence, time, echo ? "action.deadline" : "action.settled",
        [
          "kind": "mute", "origin": echo ? "muteEcho" : "application", "fulfilled": true,
          "muted": true, "callUUID": "c1", "apiKind": "livecommunicationkit", "provider": "p1",
          "actionID": id, "transactionID": "transaction-\(id)",
        ])
    }
    let first = try mute(1, 0, "m1")
    let latest = try mute(2, 10, "m2")
    let firstEcho = try mute(3, 15, "e1", echo: true)
    let latestEcho = try mute(4, 25, "e2", echo: true)
    #expect(
      try metric("muteEcho", [first, latest, firstEcho]).actualMS == nil,
      "An older outstanding fulfillment makes the first matching echo ambiguous")
    #expect(
      try metric("muteEcho", [first, latest, firstEcho, latestEcho]).actualMS == nil,
      "Completing both echoes doesn't attribute or order them")
    #expect(
      try metric("muteEcho", [latest, firstEcho, latestEcho]).actualMS == nil,
      "Evicted history may hide an older outstanding fulfillment")

    let subsequent = try mute(5, 100, "m3")
    let subsequentEcho = try mute(6, 115, "e3", echo: true)
    #expect(
      try metric(
        "muteEcho", [first, latest, firstEcho, latestEcho, subsequent, subsequentEcho]
      ).actualMS == 15, "A later isolated fulfillment is measured once older echoes arrive")

    let duplicate = try mute(2, 1, "m1")
    let completedEcho = try mute(3, 15, "e1", echo: true)
    let duplicateEcho = try mute(4, 16, "e1", echo: true)
    #expect(
      try metric(
        "muteEcho",
        [first, duplicate, completedEcho, duplicateEcho, subsequent, subsequentEcho]
      ).actualMS == 15, "Duplicate action IDs neither create nor consume fulfillments")
    let repeatedEndpoint = try mute(6, 115, "e1", echo: true)
    #expect(
      try metric(
        "muteEcho",
        [first, duplicate, completedEcho, duplicateEcho, subsequent, repeatedEndpoint]
      ).actualMS == nil, "An echo seen before the latest fulfillment can't end its interval")
    let repeatedStart = try mute(5, 100, "m1")
    #expect(
      try metric(
        "muteEcho",
        [first, duplicate, completedEcho, duplicateEcho, repeatedStart, subsequentEcho]
      ).actualMS == nil, "A duplicate fulfillment can't start a new measurement")
    var oppositeStart = subsequent
    oppositeStart.muted = false
    var oppositeEcho = repeatedEndpoint
    oppositeEcho.muted = false
    #expect(
      try metric(
        "muteEcho",
        [first, duplicate, completedEcho, duplicateEcho, oppositeStart, oppositeEcho]
      ).actualMS == nil, "Echo IDs can't be reused for another value")
    var historicalFalseEcho = try mute(1, 0, "historical-e1", echo: true)
    historicalFalseEcho.muted = false
    let outstandingTrue = try mute(2, 10, "historical-m1")
    let reusedTrueEcho = try mute(3, 15, "historical-e1", echo: true)
    let latestTrue = try mute(4, 20, "historical-m2")
    let freshTrueEcho = try mute(5, 35, "historical-e2", echo: true)
    #expect(
      try metric(
        "muteEcho",
        [historicalFalseEcho, outstandingTrue, reusedTrueEcho, latestTrue, freshTrueEcho]
      ).actualMS == nil, "A historical echo ID can't discharge an obligation for another value")
  }

  @Test func muteValuesComeFromTheDeliveredTransactions() throws {
    func decode(_ rows: [[String: Any]]) throws -> [RuntimeEvent] {
      try rows.enumerated().map { offset, row in
        try event(
          offset + 1, #require(row["t_ms"] as? Double), #require(row["event"] as? String), row)
      }
    }
    let application: [String: Any] = [
      "event": "transaction.delivered", "t_ms": 0.0, "transactionID": "t1",
      "provider": "provider1", "origin": "application", "actionIDs": ["m1"], "callUUIDs": ["c1"],
      "kinds": ["CXSetMutedCallAction"], "parameters": [["muted": true]],
    ]
    let fulfilled: [String: Any] = [
      "event": "action.settled", "t_ms": 100.0, "kind": "mute", "actionID": "m1",
      "transactionID": "t1", "callUUID": "c1", "provider": "provider1", "origin": "application",
      "apiKind": "callkit", "fulfilled": true,
    ]
    let echoTransaction: [String: Any] = [
      "event": "transaction.delivered", "t_ms": 115.0, "transactionID": "t2",
      "provider": "provider1", "origin": "muteEcho", "actionIDs": ["m2"], "callUUIDs": ["c1"],
      "kinds": ["CXSetMutedCallAction"], "parameters": [["muted": true]],
    ]
    let echo: [String: Any] = [
      "event": "action.deadline", "t_ms": 115.0, "kind": "mute", "actionID": "m2",
      "transactionID": "t2", "callUUID": "c1", "provider": "provider1", "origin": "muteEcho",
      "apiKind": "callkit",
    ]
    let native = [application, fulfilled, echoTransaction, echo]
    let measured = try metric("muteEcho", decode(native))
    #expect(
      measured.actualMS == 15 && measured.startSequence == 2 && measured.endSequence == 4,
      "Mute action rows omit the value; the delivered transactions' parameters provide it")

    let mutations: [(Int, [String: Any])] = [
      (0, ["event": "runtime.installed"]), (0, ["provider": "other"]),
      (0, ["transactionID": "other"]), (0, ["actionIDs": ["other"]]),
      (0, ["callUUIDs": ["other"]]), (0, ["parameters": [[:]]]),
      (0, ["kinds": ["CXSetHeldCallAction"]]), (0, ["origin": "system"]), (0, ["t_ms": 101.0]),
      (
        0,
        [
          "actionIDs": ["m1", "m1"], "callUUIDs": ["c1", "c1"],
          "kinds": ["CXSetMutedCallAction", "CXSetMutedCallAction"],
          "parameters": [["muted": true], ["muted": true]],
        ]
      ),
      (0, ["actionIDs": ["m1", "other"]]), (1, ["muted": false]),
      (2, ["parameters": [["muted": false]]]), (2, ["provider": "other"]),
      (2, ["event": "runtime.installed"]),
    ]
    for (index, fields) in mutations {
      var rows = native
      rows[index].merge(fields) { _, new in new }
      #expect(
        try metric("muteEcho", decode(rows)).actualMS == nil,
        "Unknown or contradictory transaction metadata is unavailable: \(fields)")
    }
    #expect(
      try metric("muteEcho", decode([application, application, fulfilled, echoTransaction, echo]))
        .actualMS == nil, "A reused transaction ID is ambiguous")
    var multiple = native
    multiple[0].merge([
      "actionIDs": ["unrelated", "m1"], "callUUIDs": ["other", "c1"],
      "kinds": ["CXEndCallAction", "CXSetMutedCallAction"], "parameters": [[:], ["muted": true]],
    ]) { _, new in new }
    #expect(
      try metric("muteEcho", decode(multiple)).actualMS == 15,
      "The parameter is selected by action ID, not by position")
    var unmute = native
    unmute[0]["parameters"] = [["muted": false]]
    unmute[2]["parameters"] = [["muted": false]]
    #expect(try metric("muteEcho", decode(unmute)).actualMS == 15)
    var overlappingTransaction = application
    overlappingTransaction.merge(["t_ms": 105.0, "transactionID": "t3", "actionIDs": ["m3"]]) {
      _, new in new
    }
    var overlappingFulfillment = fulfilled
    overlappingFulfillment.merge(["t_ms": 110.0, "transactionID": "t3", "actionID": "m3"]) {
      _, new in new
    }
    #expect(
      try metric(
        "muteEcho",
        decode([
          application, fulfilled, overlappingTransaction, overlappingFulfillment, echoTransaction,
          echo,
        ])
      ).actualMS == nil, "Overlapping fulfillments don't establish which one owns an echo")
    var unknownOlder = fulfilled
    unknownOlder.merge(["t_ms": -10.0, "transactionID": "missing", "actionID": "older"]) {
      _, new in new
    }
    #expect(
      try metric(
        "muteEcho", decode([["event": "runtime.installed", "t_ms": -20.0], unknownOlder] + native)
      ).actualMS == nil, "An unresolved older obligation isn't skipped")
    let specifications: [(Bool, Bool, String, String, Double)] = [
      (true, false, "historical-e1", "he1-false", 0), (false, true, "historical-m1", "hm1", 10),
      (true, true, "historical-e1", "he1-true", 15), (false, true, "historical-m2", "hm2", 20),
      (true, true, "historical-e2", "he2", 35),
    ]
    var historical: [[String: Any]] = []
    for (isEcho, value, id, transactionID, time) in specifications {
      var delivered = isEcho ? echoTransaction : application
      delivered.merge([
        "t_ms": time, "transactionID": transactionID, "actionIDs": [id],
        "parameters": [["muted": value]],
      ]) { _, new in new }
      var action = isEcho ? echo : fulfilled
      action.merge(["t_ms": time, "transactionID": transactionID, "actionID": id]) { _, new in new }
      historical += [delivered, action]
    }
    #expect(
      try metric("muteEcho", decode(historical)).actualMS == nil,
      "A duplicate echo for another value can't discharge the obligation")
  }
}
