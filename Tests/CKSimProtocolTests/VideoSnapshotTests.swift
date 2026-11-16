import Foundation
import Testing

@testable import CKSimProtocol

struct VideoSnapshotTests {
  @Test(arguments: [false, true])
  func snapshotRoundTrip(hasVideo: Bool) throws {
    let id = UUID()
    let state = CallSnapshot.State(
      uuid: id, outgoing: false, connected: true, held: false, ended: false,
      muted: false, ringing: false, hasVideo: hasVideo, callerName: "Caller", handle: "handle",
      capabilities: [])
    for relationship in [
      CallSnapshot.Relationship.callkit(group: id),
      .livecommunicationkit(availableSystemChoices: []),
    ] {
      let call = CallSnapshot(state: state, relationship: relationship)
      let bytes = try JSONEncoder().encode(call)
      #expect(try JSONDecoder().decode(CallSnapshot.self, from: bytes) == call)
      var old = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
      old.removeValue(forKey: "hasVideo")
      let restored = try JSONDecoder().decode(
        CallSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
      #expect(!restored.state.hasVideo)
      old["hasVideo"] = "true"
      #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
          CallSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
      }
    }
  }
  @Test func retainedHistoryRoundTripAndOlderRecording() throws {
    var call = RetainedCall(uuid: UUID(), state: .connected, reportedAtMS: 1)
    call.hasVideo = true
    call.videoChanges = [
      .init(atMS: 2, hasVideo: true), .init(atMS: 3, hasVideo: false),
      .init(atMS: 4, hasVideo: true),
    ]
    let bytes = try JSONEncoder().encode(call)
    #expect(try JSONDecoder().decode(RetainedCall.self, from: bytes) == call)
    var old = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    old.removeValue(forKey: "hasVideo")
    old.removeValue(forKey: "videoChanges")
    let restored = try JSONDecoder().decode(
      RetainedCall.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(!restored.hasVideo)
    #expect(restored.videoChanges.isEmpty)
  }
}
