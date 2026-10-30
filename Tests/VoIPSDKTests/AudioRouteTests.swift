import Foundation
import Testing

@testable import VoIPSDK

struct AudioRouteTests {
  @Test func identifiersKeepTheirWireString() throws {
    let id = AudioRoute.ID(rawValue: "input:microphone")
    let wire = Data(#""input:microphone""#.utf8)
    #expect(id.rawValue == "input:microphone")
    #expect(try JSONEncoder().encode(id) == wire)
    #expect(try JSONDecoder().decode(AudioRoute.ID.self, from: wire) == id)
  }

  @Test(arguments: ["7", "null", "true", #"{"rawValue":"speaker"}"#])
  func identifiersRejectNonStringWireValues(json: String) {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(AudioRoute.ID.self, from: Data(json.utf8))
    }
  }

  @Test func snapshotsKeepTheirWireShape() throws {
    let wire = Data(
      #"{"revision":7,"routes":[{"id":"speaker","name":"Speaker","type":"Speaker"}],"current":null}"#
        .utf8)
    let snapshot = try JSONDecoder().decode(AudioRoutesSnapshot.self, from: wire)
    #expect(snapshot.routes.first?.id == AudioRoute.ID(rawValue: "speaker"))
    #expect(snapshot.current == nil)
    #expect(
      try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(snapshot))
        == JSONDecoder().decode(JSONValue.self, from: wire))
  }
}
