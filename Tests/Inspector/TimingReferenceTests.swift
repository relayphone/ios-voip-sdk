import Foundation

@main
struct TimingReferenceTests {
  static func main() throws {
    let empty = RuntimeTimingReferences.project([])
    precondition(empty.map(\.id) == ["pushReport", "answerAudio", "muteEcho", "unreportedPush"])
    precondition(empty.allSatisfy { $0.actualMS == nil && $0.startSequence == nil && $0.endSequence == nil })
    precondition(empty.map(\.deviceValue) == ["≈190 ms", "≈236 ms", "8–17 ms after fulfillment", "≈4.4 s"])
    precondition(empty.allSatisfy { $0.deviceProvenance.contains("LCK · iPhone 13 · iOS 27.0") })
    precondition(empty.allSatisfy { $0.sourcePath == "docs/research/callkit-simulator-probe/livecommunicationkit/push/README.md" })
    let encoded = try JSONEncoder().encode(empty)
    let decoded = try JSONDecoder().decode([RuntimeTimingReadout].self, from: encoded)
    precondition(decoded.map(\.deviceValue) == empty.map(\.deviceValue))
    try actualIntervals()
    try missingAndUnrelatedEvents()
    try latestAttemptDoesNotReuseOldMeasurements()
    try answerInvalidation()
    try overlappingMuteEchoesAreAmbiguous()
    try muteValuesComeFromDeliveredTransactions()
    print("Inspector timing reference tests passed")
  }

  static func event(_ sequence: Int, _ time: Double, _ name: String, _ fields: [String: Any] = [:]) throws -> RuntimeEvent {
    var value: [String: Any] = ["schemaVersion": 1, "sequence": sequence, "runID": "run", "pid": 123,
                              "bundleID": "test.fixture", "event": name, "t_ms": time]
    value.merge(fields) { _, new in new }
    return try JSONDecoder().decode(RuntimeEvent.self, from: JSONSerialization.data(withJSONObject: value))
  }

  static func metric(_ name: String, _ events: [RuntimeEvent]) -> RuntimeTimingReadout {
    RuntimeTimingReferences.project(events).first { $0.id == name }!
  }

  static func actualIntervals() throws {
    let pushed = try event(1, 100, "push.received", ["pushID": "p1", "mustReport": true])
    let reported = try event(2, 290, "report.completed", ["pushID": "p1", "error": 0])
    let report = metric("pushReport", [pushed, reported])
    precondition(report.actualMS == 190 && report.startSequence == 1 && report.endSequence == 2)

    let answer = try event(3, 300, "action.deadline", ["kind": "answer", "callUUID": "c1", "actionID": "a1",
      "apiKind": "callkit", "provider": "provider1"])
    let answered = try event(4, 425, "action.settled", ["kind": "answer", "callUUID": "c1", "actionID": "a1",
      "apiKind": "callkit", "fulfilled": true])
    let audio = try event(5, 536, "audio.activated")
    let activation = metric("answerAudio", [answer, answered, audio])
    precondition(activation.actualMS == 236 && activation.startSequence == 3 && activation.endSequence == 5)
    precondition(activation.actualLabel == "Simulator · CallKit answer delivered → audio.activated")
    let join = try event(3, 300, "action.deadline", ["kind": "answer", "callUUID": "c1", "actionID": "a1",
      "apiKind": "livecommunicationkit", "provider": "provider1"])
    let joined = try event(4, 425, "action.settled", ["kind": "answer", "callUUID": "c1", "actionID": "a1",
      "apiKind": "livecommunicationkit", "fulfilled": true])
    precondition(metric("answerAudio", [join, joined, audio]).actualLabel == "Simulator · LCK join delivered → audio.activated")

    let fulfilled = try event(1, 600, "action.settled", ["kind": "mute", "origin": "application", "fulfilled": true,
      "muted": false, "callUUID": "c1", "actionID": "m1", "transactionID": "t1", "apiKind": "livecommunicationkit", "provider": "provider1"])
    let echo = try event(2, 615, "action.deadline", ["kind": "mute", "origin": "muteEcho", "muted": false,
      "callUUID": "c1", "actionID": "m2", "transactionID": "t2", "apiKind": "livecommunicationkit", "provider": "provider1"])
    let mute = metric("muteEcho", [fulfilled, echo])
    precondition(mute.actualMS == 15 && mute.startSequence == 1 && mute.endSequence == 2)

    let expired = try event(2, 4500, "diagnostic.pushReportExpired", ["pushID": "p1"])
    let deadline = metric("unreportedPush", [pushed, expired])
    precondition(deadline.actualMS == 4400 && deadline.startSequence == 1 && deadline.endSequence == 2)
  }

  static func missingAndUnrelatedEvents() throws {
    let pushed = try event(1, 100, "push.received", ["pushID": "p1", "mustReport": true])
    for name in ["report.completed", "diagnostic.pushReportExpired"] {
      let id = name == "report.completed" ? "pushReport" : "unreportedPush"
      for (time, fields) in [(290.0, ["pushID": "other"] as [String: Any]),
                             (90.0, ["pushID": "p1"]),
                             (290.0, ["pushID": "p1", "runID": "other"]),
                             (290.0, ["pushID": "p1", "pid": 999])] {
        let unrelated = try event(2, time, name, fields)
        precondition(metric(id, [pushed, unrelated]).actualMS == nil)
      }
      let completed = try event(2, 290, name, ["pushID": "p1"])
      precondition(metric(id, [completed]).actualMS == nil, "Evicted start must be unavailable")
      let missingIDs = try [event(1, 100, "push.received"), event(2, 290, name)]
      precondition(metric(id, missingIDs).actualMS == nil)
    }
    let optional = try event(1, 100, "push.received", ["pushID": "p1", "mustReport": false])
    let expired = try event(2, 4500, "diagnostic.pushReportExpired", ["pushID": "p1"])
    precondition(metric("unreportedPush", [optional, expired]).actualMS == nil)
    let invalidTime = RuntimeEvent(schemaVersion: 1, sequence: 1, runID: "run", pid: 123,
      bundleID: "test.fixture", event: "push.received", t_ms: .nan, pushID: "p1")
    let report = try event(2, 290, "report.completed", ["pushID": "p1"])
    precondition(metric("pushReport", [invalidTime, report]).actualMS == nil)
    let filtered = try event(2, 2170, "report.completed", ["pushID": "p1", "error": 3])
    precondition(metric("pushReport", [pushed, filtered]).actualMS == nil,
      "A filtered failure cannot be compared silently with the successful device report")
    precondition(metric("pushReport", [pushed, report]).actualMS == nil, "Unknown outcome is unavailable")
    let controlFailure = try event(3, 300, "control.completed", ["error": "Rejected command"])
    precondition(controlFailure.title == "control.completed", "String control errors must remain decodable")

    let app: [String: Any] = ["kind": "mute", "origin": "application", "fulfilled": true, "muted": true,
      "callUUID": "c1", "actionID": "m1", "transactionID": "t1", "apiKind": "livecommunicationkit", "provider": "provider1"]
    let fulfilled = try event(1, 600, "action.settled", app)
    let baseEcho: [String: Any] = ["kind": "mute", "origin": "muteEcho", "muted": true,
      "callUUID": "c1", "actionID": "m2", "transactionID": "t2", "apiKind": "livecommunicationkit", "provider": "provider1"]
    for change: [String: Any] in [["muted": false], ["callUUID": "other"], ["apiKind": "callkit"],
                                 ["provider": "other"], ["origin": "system"], ["actionID": ""], ["transactionID": ""]] {
      let fields = baseEcho.merging(change) { _, new in new }
      let wrongEcho = try event(2, 615, "action.deadline", fields)
      precondition(metric("muteEcho", [fulfilled, wrongEcho]).actualMS == nil)
    }
    let pending = try event(1, 500, "action.deadline", app)
    let echo = try event(2, 615, "action.deadline", baseEcho)
    precondition(metric("muteEcho", [pending, echo]).actualMS == nil,
      "Delivery without app fulfillment must not produce a mute interval")
    for provider in [nil, ""] as [String?] {
      var unidentifiedApp = app
      var unidentifiedEcho = baseEcho
      unidentifiedApp["provider"] = provider
      unidentifiedEcho["provider"] = provider
      let unidentified = try [event(1, 600, "action.settled", unidentifiedApp),
                              event(2, 615, "action.deadline", unidentifiedEcho)]
      precondition(metric("muteEcho", unidentified).actualMS == nil,
        "Two unidentified providers cannot establish a same-provider mute echo")
    }
  }

  static func latestAttemptDoesNotReuseOldMeasurements() throws {
    let pushed = try event(1, 100, "push.received", ["pushID": "p1", "mustReport": true])
    let report = try event(2, 290, "report.completed", ["pushID": "p1"])
    let next = try event(3, 500, "push.received", ["pushID": "p2", "mustReport": true])
    precondition(metric("pushReport", [pushed, report, next]).actualMS == nil)
    let answer: [String: Any] = ["kind": "answer", "callUUID": "c1", "actionID": "a1", "apiKind": "callkit"]
    let delivered = try event(1, 100, "action.deadline", answer)
    let audio = try event(2, 336, "audio.activated")
    let newest = try event(3, 500, "action.deadline", answer.merging(["actionID": "a2"]) { _, new in new })
    precondition(metric("answerAudio", [delivered, audio, newest]).actualMS == nil)
    let unknown = try event(3, 500, "action.deadline", answer.merging(["apiKind": "unknown"]) { _, new in new })
    let latestAudio = try event(4, 736, "audio.activated")
    precondition(metric("answerAudio", [unknown, latestAudio]).actualMS == nil)

    let app: [String: Any] = ["kind": "mute", "origin": "application", "fulfilled": true, "muted": true,
      "callUUID": "c1", "apiKind": "callkit"]
    let fulfilled = try event(1, 100, "action.settled", app)
    let echo = try event(2, 115, "action.deadline", app.merging(["origin": "muteEcho"]) { _, new in new })
    let failed = try event(3, 200, "action.settled", app.merging(["fulfilled": false]) { _, new in new })
    precondition(metric("muteEcho", [fulfilled, echo, failed]).actualMS == nil)
  }

  static func answerInvalidation() throws {
    let delivered = try event(1, 100, "action.deadline", ["kind": "answer", "callUUID": "c1", "actionID": "a1", "apiKind": "callkit"])
    let audio = try event(4, 336, "audio.activated")
    precondition(metric("answerAudio", [delivered, audio]).actualMS == nil, "A pending answer cannot own process-wide audio")
    let fulfilled = try event(2, 220, "action.settled", ["kind": "answer", "actionID": "a1", "callUUID": "c1",
      "apiKind": "callkit", "fulfilled": true])
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
      ("action.settled", ["kind": "answer", "actionID": "older-answer", "callUUID": "c2", "apiKind": "callkit", "fulfilled": true]),
      ("action.deadline", ["kind": "answer", "actionID": "other-answer", "callUUID": "c2", "apiKind": "callkit"]),
      ("report.connected", [:])
    ]
    for (name, fields) in blockers {
      let blocked = try event(3, 250, name, fields)
      precondition(metric("answerAudio", [delivered, fulfilled, blocked, audio]).actualMS == nil,
        "Ambiguous or invalidated activation after \(name) must be unavailable")
    }
    precondition(metric("answerAudio", [delivered, fulfilled, audio]).actualMS == 236,
      "The interval starts at delivery, not fulfillment")
  }

  static func overlappingMuteEchoesAreAmbiguous() throws {
    func mute(_ sequence: Int, _ time: Double, _ id: String, echo: Bool = false) throws -> RuntimeEvent {
      try event(sequence, time, echo ? "action.deadline" : "action.settled", [
        "kind": "mute", "origin": echo ? "muteEcho" : "application", "fulfilled": true,
        "muted": true, "callUUID": "c1", "apiKind": "livecommunicationkit", "provider": "p1",
        "actionID": id, "transactionID": "transaction-\(id)"
      ])
    }
    let first = try mute(1, 0, "m1")
    let latest = try mute(2, 10, "m2")
    let firstEcho = try mute(3, 15, "e1", echo: true)
    let latestEcho = try mute(4, 25, "e2", echo: true)
    precondition(metric("muteEcho", [first, latest, firstEcho]).actualMS == nil,
      "An older outstanding fulfillment makes the first matching echo ambiguous")
    precondition(metric("muteEcho", [first, latest, firstEcho, latestEcho]).actualMS == nil,
      "Completing both echoes does not prove their individual attribution or ordering")
    precondition(metric("muteEcho", [latest, firstEcho, latestEcho]).actualMS == nil,
      "Evicted history may hide an older outstanding fulfillment")

    let subsequent = try mute(5, 100, "m3")
    let subsequentEcho = try mute(6, 115, "e3", echo: true)
    precondition(metric("muteEcho", [first, latest, firstEcho, latestEcho, subsequent, subsequentEcho]).actualMS == 15,
      "A later isolated fulfillment is comparable once all older echoes have arrived")

    let duplicate = try mute(2, 1, "m1")
    let completedEcho = try mute(3, 15, "e1", echo: true)
    let duplicateEcho = try mute(4, 16, "e1", echo: true)
    precondition(metric("muteEcho", [first, duplicate, completedEcho, duplicateEcho, subsequent, subsequentEcho]).actualMS == 15,
      "Duplicate action IDs cannot create or consume extra outstanding fulfillments")
    let repeatedEndpoint = try mute(6, 115, "e1", echo: true)
    precondition(metric("muteEcho", [first, duplicate, completedEcho, duplicateEcho, subsequent, repeatedEndpoint]).actualMS == nil,
      "An echo already seen before the latest fulfillment cannot be reused as its endpoint")
    let repeatedStart = try mute(5, 100, "m1")
    precondition(metric("muteEcho", [first, duplicate, completedEcho, duplicateEcho, repeatedStart, subsequentEcho]).actualMS == nil,
      "A duplicate fulfillment cannot become a new measurement start")
    var oppositeStart = subsequent
    oppositeStart.muted = false
    var oppositeEcho = repeatedEndpoint
    oppositeEcho.muted = false
    precondition(metric("muteEcho", [first, duplicate, completedEcho, duplicateEcho, oppositeStart, oppositeEcho]).actualMS == nil,
      "Echo IDs cannot be reused even when their reported value changes")
  }

  static func muteValuesComeFromDeliveredTransactions() throws {
    func decode(_ rows: [[String: Any]]) throws -> [RuntimeEvent] {
      try rows.enumerated().map { offset, row in
        try event(offset + 1, row["t_ms"] as! Double, row["event"] as! String, row)
      }
    }
    let application: [String: Any] = ["event": "transaction.delivered", "t_ms": 0.0,
      "transactionID": "t1", "provider": "provider1", "origin": "application",
      "actionIDs": ["m1"], "callUUIDs": ["c1"], "kinds": ["CXSetMutedCallAction"], "parameters": [["muted": true]]]
    let fulfilled: [String: Any] = ["event": "action.settled", "t_ms": 100.0, "kind": "mute",
      "actionID": "m1", "transactionID": "t1", "callUUID": "c1", "provider": "provider1",
      "origin": "application", "apiKind": "callkit", "fulfilled": true]
    let echoTransaction: [String: Any] = ["event": "transaction.delivered", "t_ms": 115.0,
      "transactionID": "t2", "provider": "provider1", "origin": "muteEcho",
      "actionIDs": ["m2"], "callUUIDs": ["c1"], "kinds": ["CXSetMutedCallAction"], "parameters": [["muted": true]]]
    let echo: [String: Any] = ["event": "action.deadline", "t_ms": 115.0, "kind": "mute",
      "actionID": "m2", "transactionID": "t2", "callUUID": "c1", "provider": "provider1",
      "origin": "muteEcho", "apiKind": "callkit"]
    let native = [application, fulfilled, echoTransaction, echo]
    let measured = metric("muteEcho", try decode(native))
    precondition(measured.actualMS == 15 && measured.startSequence == 2 && measured.endSequence == 4,
      "Native mute action rows omit muted; delivered transaction parameters provide the value")

    let mutations: [(Int, [String: Any])] = [
      (0, ["event": "runtime.installed"]), (0, ["provider": "other"]), (0, ["transactionID": "other"]),
      (0, ["actionIDs": ["other"]]), (0, ["callUUIDs": ["other"]]), (0, ["parameters": [[:]]]),
      (0, ["kinds": ["CXSetHeldCallAction"]]), (0, ["origin": "system"]), (0, ["t_ms": 101.0]),
      (0, ["actionIDs": ["m1", "m1"], "callUUIDs": ["c1", "c1"],
           "kinds": ["CXSetMutedCallAction", "CXSetMutedCallAction"], "parameters": [["muted": true], ["muted": true]]]),
      (0, ["actionIDs": ["m1", "other"]]), (1, ["muted": false]), (2, ["parameters": [["muted": false]]]),
      (2, ["provider": "other"]), (2, ["event": "runtime.installed"])
    ]
    for (index, fields) in mutations {
      var rows = native
      rows[index].merge(fields) { _, new in new }
      let decoded = try decode(rows)
      precondition(metric("muteEcho", decoded).actualMS == nil, "Unknown or contradictory transaction metadata is unavailable")
    }
    let duplicate = try decode([application, application, fulfilled, echoTransaction, echo])
    precondition(metric("muteEcho", duplicate).actualMS == nil, "A reused transaction ID is ambiguous")
    var multiple = native
    multiple[0].merge(["actionIDs": ["unrelated", "m1"], "callUUIDs": ["other", "c1"],
      "kinds": ["CXEndCallAction", "CXSetMutedCallAction"], "parameters": [[:], ["muted": true]]]) { _, new in new }
    let indexed = try decode(multiple)
    precondition(metric("muteEcho", indexed).actualMS == 15, "Select the parameter by the matching action ID, not array position zero")
    var unmute = native
    unmute[0]["parameters"] = [["muted": false]]
    unmute[2]["parameters"] = [["muted": false]]
    let unmuted = try decode(unmute)
    precondition(metric("muteEcho", unmuted).actualMS == 15, "Unmute resolves the false value from both transactions")
    var overlappingTransaction = application
    overlappingTransaction.merge(["t_ms": 105.0, "transactionID": "t3", "actionIDs": ["m3"]]) { _, new in new }
    var overlappingFulfillment = fulfilled
    overlappingFulfillment.merge(["t_ms": 110.0, "transactionID": "t3", "actionID": "m3"]) { _, new in new }
    let overlapping = try decode([application, fulfilled, overlappingTransaction, overlappingFulfillment, echoTransaction, echo])
    precondition(metric("muteEcho", overlapping).actualMS == nil, "Native metadata does not establish which overlapping fulfillment owns an echo")
    var unknownOlder = fulfilled
    unknownOlder.merge(["t_ms": -10.0, "transactionID": "missing", "actionID": "older"]) { _, new in new }
    let unknown = try decode([["event": "runtime.installed", "t_ms": -20.0], unknownOlder] + native)
    precondition(metric("muteEcho", unknown).actualMS == nil, "An unresolved older obligation cannot be silently skipped")
  }
}
