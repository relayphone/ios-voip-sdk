#if os(iOS) && targetEnvironment(simulator)
  import Foundation
  import Testing

  struct JournalEntryTests {
    @Test(arguments: [0, 1648, 5000], [30_000, 31_648])
    func advertisedIntervalExcludesDelayBeforeFrameworkDelivery(
      delayMS: Int, intervalMS: Int
    ) throws {
      let issuedAt = 1_000_000
      let deliveredAt = issuedAt + delayMS
      let fields = """
        {"schemaVersion":1,"sequence":1,"runID":"deadline-test","pid":123,
        "bundleID":"dev.example","event":"lck.fixture.perform","t_ms":0,
        "wallTimeMS":\(deliveredAt + 5000),"uptimeNanoseconds":123,
        "issuedAtMS":\(issuedAt),"advertisedAtMS":\(deliveredAt),
        "advertisedDeadlineMS":\(deliveredAt + intervalMS)}
        """
      let entry = try JSONDecoder().decode(Entry.self, from: Data(fields.utf8))
      let advertised = try #require(entry.advertisedIntervalMS)
      #expect(advertised == Double(intervalMS))
      #expect((29_000...31_000).contains(advertised) == (intervalMS == 30_000))
    }

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
