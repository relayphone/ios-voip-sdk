import Foundation
import Testing

@testable import CKSimInspector

struct VideoObservationTests {
  @Test(arguments: [false, true])
  func confirmedValueAppearsInTimeline(hasVideo: Bool) throws {
    let row = try event(
      1, 42, "call.videoChanged", ["callUUID": UUID().uuidString, "hasVideo": hasVideo])
    #expect(row.hasVideo == hasVideo)
    #expect(row.title == (hasVideo ? "Video enabled" : "Video disabled"))
    #expect(row.detail.contains(hasVideo ? "Video" : "Audio only"))
    let copy = try JSONDecoder().decode(RuntimeEvent.self, from: JSONEncoder().encode(row))
    #expect(copy.hasVideo == hasVideo)
    #expect(copy.t_ms == 42)
  }
}
