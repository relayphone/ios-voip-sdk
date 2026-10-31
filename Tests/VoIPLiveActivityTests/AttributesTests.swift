import Foundation
import Testing
import VoIPCore

@testable import VoIPLiveActivity

let callID = CallID(rawValue: "call-1")
let startedAt = Date(timeIntervalSince1970: 1_799_999_990)

let alice: Party = {
  do {
    return try Party(
      handle: Handle(kind: .phoneNumber, value: "+14155550123"), displayName: "Alice")
  } catch {
    preconditionFailure("The fixture handle is valid: \(error)")
  }
}()

@Suite struct AttributesTests {
  @Test func copiesTheCall() {
    let call = Call(
      id: callID, isIncoming: true, parties: [alice], status: .previewing(.policy),
      hasVideo: true, metadata: ["room": "room-1"])
    #expect(
      CallPreviewAttributes(call)
        == CallPreviewAttributes(
          callID: callID, parties: [alice], hasVideo: true, metadata: ["room": "room-1"]))
  }

  @Test func roundTripsEveryHandleAndName() throws {
    let party = try Party(
      handles: [
        Handle(kind: .emailAddress, value: "alice@example.com"),
        Handle(kind: .phoneNumber, value: "+14155550123"), Handle(kind: .generic, value: "user-42"),
      ], displayName: "Alice")
    let attributes = CallPreviewAttributes(
      callID: callID, parties: [party, alice], hasVideo: true,
      metadata: ["route": ["hops": [1, "sip", .null]]])
    #expect(try decode(CallPreviewAttributes.self, encode(attributes)) == attributes)
  }

  @Test(arguments: [
    (CallStatus.previewing(.filtered(.doNotDisturb)), CallPreviewStatus?.some(.filtered)),
    (.previewing(.filtered(.blockList)), .filtered),
    (.previewing(.answeredElsewhere), .answeredElsewhere),
    (.previewing(.policy), .policy),
    (.ended(.endedRemotely), .ended),
    (.ringing, nil), (.dialing, nil), (.connecting, nil), (.connected, nil), (.reconnecting, nil),
  ])
  func statusFollowsTheCall(_ call: CallStatus, _ preview: CallPreviewStatus?) {
    #expect(CallPreviewStatus(call) == preview)
  }

  @Test func statusRawValuesAreTheContract() {
    #expect(
      CallPreviewStatus.allCases.map(\.rawValue)
        == ["filtered", "answeredElsewhere", "policy", "ended"])
  }
}

@Suite struct ContentStateTests {
  private func state(snippet: String?) -> CallPreviewAttributes.ContentState {
    CallPreviewAttributes.ContentState(
      status: .policy, startedAt: startedAt, snippet: snippet, isJoinable: true)
  }

  @Test func keepsASnippetOfTheMaximumLength() {
    let text = String(
      repeating: "é", count: CallPreviewAttributes.ContentState.maximumSnippetLength)
    #expect(state(snippet: text).snippet == text)
  }

  @Test func shortensALongerSnippet() {
    let text = String(repeating: "👋🏽", count: 241)
    let snippet = state(snippet: text).snippet
    #expect(snippet?.count == 240)
    #expect(snippet == String(repeating: "👋🏽", count: 239) + "…")
  }

  @Test func shortensASnippetSetLater() {
    var state = state(snippet: nil)
    state.snippet = String(repeating: "a", count: 300)
    #expect(state.snippet?.count == 240)
    state.snippet = nil
    #expect(state.snippet == nil)
  }

  @Test func encodesStartedAtAsUnixSeconds() throws {
    let state = CallPreviewAttributes.ContentState(
      status: .filtered, startedAt: Date(timeIntervalSince1970: 1_799_999_990.5),
      isJoinable: false)
    #expect(
      try encode(state)
        == ["status": "filtered", "startedAt": 1_799_999_990.5, "isJoinable": false])
  }

  /// The system decodes pushes with `JSONDecoder`'s default strategies; the content state reads
  /// its own dates, whatever the strategy.
  @Test func readsUnixSecondsWhateverTheDateStrategy() throws {
    let json = Data(#"{"status":"policy","startedAt":1799999990,"isJoinable":true}"#.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let state = try decoder.decode(CallPreviewAttributes.ContentState.self, from: json)
    #expect(state.startedAt == startedAt)
  }
}

@Suite struct SizeTests {
  private let state = CallPreviewAttributes.ContentState(
    status: .filtered, startedAt: startedAt, statusText: "Your assistant is answering",
    snippet: String(repeating: "a", count: 240), isJoinable: true)

  @Test func fitsAUsualPreview() {
    let attributes = CallPreviewAttributes(
      callID: callID, parties: [alice], metadata: ["room": "room-1"])
    #expect(attributes.fits(with: state))
  }

  @Test func doesNotFitMoreThan4KB() throws {
    let empty = CallPreviewAttributes(callID: callID, parties: [alice])
    let budget =
      CallPreviewAttributes.maximumSize - (try JSONEncoder().encode(empty).count)
      - (try JSONEncoder().encode(state).count)
    // `"metadata":{}` grows by the key, its quotes, the colon and the value's quotes.
    let filler = budget - #""k":"""#.utf8.count
    let fitting = CallPreviewAttributes(
      callID: callID, parties: [alice],
      metadata: ["k": .string(String(repeating: "x", count: filler))])
    #expect(fitting.fits(with: state))
    let tooLarge = CallPreviewAttributes(
      callID: callID, parties: [alice],
      metadata: ["k": .string(String(repeating: "x", count: filler + 1))])
    #expect(!tooLarge.fits(with: state))
  }

  @Test func doesNotFitWhatCannotBeEncoded() {
    let attributes = CallPreviewAttributes(
      callID: callID, parties: [alice], metadata: ["ratio": .number(.nan)])
    #expect(!attributes.fits(with: state))
  }
}
