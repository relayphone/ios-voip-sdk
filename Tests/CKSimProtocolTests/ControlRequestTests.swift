import CKSimProtocol
import Foundation
import Testing

struct ControlRequestTests {
  private let id = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
  private let identity = #""runID":"run_123","pid":123,"bundleID":"dev.example.app""#

  private func wire(_ parameters: String) -> Data {
    Data("{\"id\":\"\(id.uuidString)\",\(identity),\(parameters)}".utf8)
  }

  @Test func existingStatusRequestRetainsItsFlatWireFormat() throws {
    let request = try ControlRequest.decode(wire(#""operation":"status","metadata":"additive""#))
    #expect(request.id == id)
    #expect(request.target.runID == "run_123")
    #expect(request.target.pid == 123)
    #expect(request.target.bundleID == "dev.example.app")
    #expect(request.operation == .status)
    #expect(try ControlRequest.decode(JSONEncoder().encode(request)) == request)
    let header = try ControlRequest.Header.decode(wire(#""operation":"status""#))
    #expect(header.id == id && header.target == request.target && header.operationName == "status")
  }

  @Test func callControlsCarryOnlyTheirOwnParameters() throws {
    let call = UUID(uuidString: "B0000000-0000-4000-8000-000000000001")!
    let active = UUID(uuidString: "B0000000-0000-4000-8000-000000000002")!
    let held = UUID(uuidString: "B0000000-0000-4000-8000-000000000003")!
    let cases: [(String, ControlRequest.Operation)] = [
      (#""operation":"events""#, .events),
      (#""operation":"inspect-adapter""#, .inspectAdapter),
      (#""operation":"reset""#, .reset),
      (#""operation":"incoming-filter","reason":"do-not-disturb""#, .incomingFilter(.doNotDisturb)),
      (#""operation":"answer""#, .call(.answer(call))),
      (#""operation":"decline""#, .call(.decline(call))),
      (#""operation":"end""#, .call(.end(call))),
      (
        #""operation":"hold","held":true,"applicationRequest":true"#,
        .call(.hold(call, held: true, origin: .application))
      ),
      (
        #""operation":"merge","groupWithCallUUID":"\#(active)""#,
        .call(.merge(call, with: active, origin: .system))
      ),
      (#""operation":"unmerge""#, .call(.unmerge(call, origin: .system))),
      (#""operation":"mute","muted":false"#, .call(.mute(call, muted: false))),
      (#""operation":"tones","digits":"12*#aD""#, .call(.tones(call, digits: "12*#aD"))),
      (
        #""operation":"hold-and-accept","activeCallUUID":"\#(active)""#,
        .call(.holdAndAccept(call, active: active))
      ),
      (
        #""operation":"end-and-accept","activeCallUUID":"\#(active)""#,
        .call(.endAndAccept(call, active: active))
      ),
      (
        #""operation":"end-held-and-accept","activeCallUUID":"\#(active)","heldCallUUID":"\#(held)""#,
        .call(.endHeldAndAccept(call, active: active, held: held))
      ),
    ]
    for (parameters, expected) in cases {
      let callField =
        parameters.contains(#""operation":"incoming-filter""#)
          || parameters.contains(#""operation":"reset""#)
          || parameters.contains(#""operation":"events""#)
          || parameters.contains(#""operation":"inspect-adapter""#)
        ? "" : ",\"callUUID\":\"\(call)\""
      let request = try ControlRequest.decode(wire(parameters + callField))
      #expect(request.operation == expected)
      #expect(try ControlRequest.decode(JSONEncoder().encode(request)) == request)
    }
  }

  @Test func partialFaultUpdatesRetainOmittedSettings() throws {
    let request = try ControlRequest.decode(
      wire(#""operation":"faults","faults":{"staleAudio":false}"#))
    #expect(request.operation == .faults([.staleAudio(false)]))
    #expect(try ControlRequest.decode(JSONEncoder().encode(request)) == request)
    let reset = try ControlRequest.decode(
      wire(
        #""operation":"faults","faults":{"staleAudio":false,"reportCallbackDelayMS":0,"invalidateDuringHandoff":false,"incomingErrorCode":0}"#
      ))
    #expect(
      reset.operation
        == .faults([
          .staleAudio(false), .reportCallbackDelayMS(0), .invalidateDuringHandoff(false),
          .incomingErrorCode(0),
        ]))
    #expect(throws: (any Error).self) {
      try ControlRequest(
        id: id, target: request.target, operation: .faults([.staleAudio(true), .staleAudio(false)]))
    }
    for invalid in [
      "{}", #"{"unknown":true}"#, #"{"reportCallbackDelayMS":120001}"#,
      #"{"reportCallbackDelayMS":-1}"#, #"{"incomingErrorCode":3}"#, #"{"staleAudio":1}"#,
      #"{"staleAudio":null}"#, #"{"invalidateDuringHandoff":"false"}"#,
    ] {
      #expect(throws: (any Error).self) {
        try ControlRequest.decode(wire("\"operation\":\"faults\",\"faults\":\(invalid)"))
      }
    }
  }

  @Test func pushPayloadsPreserveApplicationJSONAndRequireReportingIntent() throws {
    let request = try ControlRequest.decode(
      wire(
        #""operation":"push","mustReport":true,"payload":{"signed":-9223372036854775808,"unsigned":18446744073709551615,"nested":[null,true,1.5,"ümlaut"]}"#
      ))
    #expect(
      request.operation
        == .push(
          PushPayload(fields: [
            "signed": .integer(.min), "unsigned": .unsigned(.max),
            "nested": .array([.null, .boolean(true), .number(1.5), .string("ümlaut")]),
          ]), mustReport: true))
    #expect(try ControlRequest.decode(JSONEncoder().encode(request)) == request)
    for fields in [
      #""payload":{}"#, #""mustReport":null,"payload":{}"#,
      #""mustReport":1,"payload":{}"#, #""mustReport":false,"payload":[]"#,
    ] {
      #expect(throws: (any Error).self) {
        try ControlRequest.decode(wire(#""operation":"push","# + fields))
      }
    }
    for count in [5112, 5113] {
      let bytes = wire(
        "\"operation\":\"push\",\"mustReport\":false,\"payload\":{\"p\":\"\(String(repeating: "a", count: count))\"}"
      )
      if count == 5112 {
        _ = try ControlRequest.decode(bytes)
      } else {
        #expect(throws: (any Error).self) { try ControlRequest.decode(bytes) }
      }
    }
  }

  @Test func malformedControlsNeverBecomeExecutableRequests() throws {
    for fields in [
      #""operation":"unknown""#, #""operation":"status","held":false"#,
      #""operation":"status","faults":{}"#, #""operation":"answer","applicationRequest":false"#,
      #""operation":"hold","callUUID":"A0000000-0000-4000-8000-000000000001","held":1"#,
      #""operation":"hold","callUUID":"A0000000-0000-4000-8000-000000000001","held":null"#,
      #""operation":"hold","callUUID":"A0000000-0000-4000-8000-000000000001","held":true,"applicationRequest":null"#,
      #""operation":"incoming-filter","reason":"unknown""#,
      #""operation":"status","schemaVersion":2"#,
      #""operation":"status","controlTransport":"unknown""#,
      #""operation":"answer","callUUID":null"#, #""operation":"answer","callUUID":"invalid""#,
      #""operation":"tones","callUUID":"A0000000-0000-4000-8000-000000000001","digits":"""#,
      #""operation":"tones","callUUID":"A0000000-0000-4000-8000-000000000001","digits":"🙂""#,
      #""operation":"merge","callUUID":"A0000000-0000-4000-8000-000000000001","groupWithCallUUID":"A0000000-0000-4000-8000-000000000001""#,
      #""operation":"hold-and-accept","callUUID":"A0000000-0000-4000-8000-000000000001","activeCallUUID":"A0000000-0000-4000-8000-000000000001""#,
    ] {
      #expect(throws: (any Error).self) { try ControlRequest.decode(wire(fields)) }
    }
    for field in ["callUUID", "activeCallUUID", "heldCallUUID"] {
      let fields =
        #""operation":"end-held-and-accept","callUUID":"A0000000-0000-4000-8000-000000000001","activeCallUUID":"A0000000-0000-4000-8000-000000000002","heldCallUUID":"A0000000-0000-4000-8000-000000000003""#
      let expression = #",?"\#(field)":"[A-Z0-9-]+""#
      let incomplete = fields.replacingOccurrences(
        of: expression, with: "", options: .regularExpression)
      #expect(throws: (any Error).self) { try ControlRequest.decode(wire(incomplete)) }
    }
    let unknown = wire(#""operation":"unknown""#)
    #expect(try ControlRequest.Header.decode(unknown).operationName == "unknown")
  }

  @Test func duplicateFieldsAndOversizedMailboxesRejectBeforeExecution() throws {
    for duplicate in [
      #""operation":"faults","faults":{"staleAudio":true,"staleAudio":false}"#,
      #""operation":"faults","faults":{"staleAudio":true,"stale\u0041udio":false}"#,
      #""operation":"status","operation":"reset""#,
    ] {
      #expect(throws: (any Error).self) { try ControlRequest.decode(wire(duplicate)) }
    }
    #expect(throws: (any Error).self) {
      try ControlRequest.Header.decode(wire(#""operation":"status","pid":999"#))
    }
    let base = wire(#""operation":"status""#)
    let maximum = base + Data(repeating: 32, count: 65_536 - base.count)
    #expect(try ControlRequest.decode(maximum).operation == .status)
    #expect(throws: (any Error).self) { try ControlRequest.decode(maximum + Data([32])) }
    #expect(throws: (any Error).self) { try ControlRequest.Header.decode(maximum + Data([32])) }
  }

  @Test func numericRoundingCannotChangeControlOrPushMeaning() throws {
    for faults in [
      #"{"reportCallbackDelayMS":120000.0000000000000001}"#,
      #"{"incomingErrorCode":4.000000000000000001}"#, #"{"reportCallbackDelayMS":1e-999}"#,
    ] {
      #expect(throws: (any Error).self) {
        try ControlRequest.decode(wire("\"operation\":\"faults\",\"faults\":\(faults)"))
      }
    }
    let fractionalPID = String(decoding: wire(#""operation":"status""#), as: UTF8.self)
      .replacingOccurrences(of: #""pid":123"#, with: #""pid":123.00000000000000001"#)
    #expect(throws: (any Error).self) { try ControlRequest.Header.decode(Data(fractionalPID.utf8)) }
    for number in ["18446744073709551617", "-9223372036854775809", "1e-999"] {
      #expect(throws: (any Error).self) {
        try ControlRequest.decode(
          wire("\"operation\":\"push\",\"mustReport\":false,\"payload\":{\"n\":\(number)}"))
      }
    }
    let values: [PushPayload.Value] = [
      .number(1), .unsigned(1), .object(["n": .number(0.5)]), .number(1e-100),
    ]
    for value in values {
      #expect(
        try JSONDecoder().decode(PushPayload.Value.self, from: JSONEncoder().encode(value)) == value
      )
    }
    #expect(PushPayload.Value.integer(.max) != .number(Double(Int64.max)))
    #expect(PushPayload.Value.unsigned(.max) != .number(Double(UInt64.max)))
  }

  @Test func numericChecksStayInsideTheAddressedControlAndPushPayload() throws {
    for metadata in [
      #"[{"payload":0},{"n":18446744073709551617}]"#,
      #"[{"faults":0},{"incomingErrorCode":4.5}]"#,
      #"{"payload":{"faults":{"incomingErrorCode":4.5}}}"#,
    ] {
      #expect(
        try ControlRequest.decode(wire(#""operation":"status","metadata":"# + metadata)).operation
          == .status)
    }
    _ = try ControlRequest.decode(
      wire(
        #""operation":"push","mustReport":false,"payload":{"incomingErrorCode":4.5,"nested":[{"pid":1.5},1e100]}"#
      ))
    for nested in [#"[18446744073709551617]"#, #"[{"n":-9223372036854775809}]"#] {
      #expect(throws: (any Error).self) {
        try ControlRequest.decode(
          wire(#""operation":"push","mustReport":false,"payload":{"nested":"# + nested + "}"))
      }
    }
  }
}
