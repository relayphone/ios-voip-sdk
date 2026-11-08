import Testing
import VoIPCore
import VoIPTesting

@Suite @VoIPActor
struct FakeMediaTests {
  @Test func originalRecordsRemainExhaustive() async throws {
    let media = FakeMedia()
    let call = Call(
      id: CallID(rawValue: "media"), isIncoming: true, parties: [], status: .connecting)
    try await media.prepare(call)
    media.activate()
    media.release(call)
    media.deactivate()
    #expect(media.records.map(originalKind) == ["prepare", "activate", "deactivate"])
    #expect(media.lifecycleRecords == [.prepare(call), .activate, .release(call), .deactivate])
  }

  private func originalKind(_ record: FakeMedia.Record) -> String {
    switch record {
    case .prepare: "prepare"
    case .activate: "activate"
    case .deactivate: "deactivate"
    }
  }
}
