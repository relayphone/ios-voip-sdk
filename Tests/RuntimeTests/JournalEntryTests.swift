#if os(iOS) && targetEnvironment(simulator)
  import Foundation
  import Testing

  struct JournalEntryTests {
    @Test func absoluteUptimeIsDecodedWithoutADefault() throws {
      let fields =
        #""schemaVersion":1,"sequence":1,"runID":"journal-test","pid":123,"bundleID":"dev.example","event":"runtime.ready","t_ms":0,"wallTimeMS":1000"#
      let bytes = Data("{\(fields),\"uptimeNanoseconds\":123456789012345}".utf8)
      let entry = try JSONDecoder().decode(Entry.self, from: bytes)
      #expect(entry.uptimeNanoseconds == 123_456_789_012_345)
      #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Entry.self, from: Data("{\(fields)}".utf8))
      }
    }
  }
#endif
