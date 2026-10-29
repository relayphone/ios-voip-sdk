import Foundation
import Testing

@testable import CKSimRuntime

struct RuntimeJournalTests {
  private struct Entry: Codable {
    let sequence: UInt64
    let value: Double
  }

  @Test func encodingFailureDoesNotConsumeSequence() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    var writer = RuntimeJournalWriter()

    #expect(throws: EncodingError.self) {
      try writer.append(to: file) { Entry(sequence: $0, value: .infinity) }
    }
    #expect(writer.sequence == 0)
    #expect(try Data(contentsOf: url).isEmpty)
    try writer.append(to: file) { Entry(sequence: $0, value: 42) }
    let result = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: url))
    #expect(result.sequence == 1)
    #expect(result.value == 42)
    #expect(writer.sequence == 1)
  }

  private enum WriteFailure: Sendable { case readOnly, closed }

  @Test(arguments: [WriteFailure.readOnly, .closed])
  private func writeFailureThrowsWithoutConsumingSequence(failure: WriteFailure) throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    var writer = RuntimeJournalWriter()
    try writer.append(to: file) { Entry(sequence: $0, value: 1) }

    let failedFile: FileHandle
    switch failure {
    case .readOnly: failedFile = try FileHandle(forReadingFrom: url)
    case .closed:
      failedFile = try FileHandle(forWritingTo: url)
      try failedFile.close()
    }
    defer { try? failedFile.close() }
    #expect(throws: (any Error).self) {
      try writer.append(to: failedFile) { Entry(sequence: $0, value: 99) }
    }
    #expect(writer.sequence == 1)
    try writer.append(to: file) { Entry(sequence: $0, value: 2) }
    let data = try Data(contentsOf: url)
    #expect(data.last == 10)
    let entries = try data.split(separator: 10).map {
      try JSONDecoder().decode(Entry.self, from: Data($0))
    }
    #expect(entries.map(\.sequence) == [1, 2])
    #expect(entries.map(\.value) == [1, 2])
    #expect(writer.sequence == 2)
  }

  @Test func absentJournalDoesNotConsumeSequence() throws {
    var writer = RuntimeJournalWriter()
    try writer.append(to: nil) { Entry(sequence: $0, value: .infinity) }
    #expect(writer.sequence == 0)
  }

  @Test func legacyFieldsRetainTheirJSONTypes() throws {
    struct Fields: Decodable {
      let enabled: Bool
      let zero: Int
      let one: Int
      let minimum: Int64
      let maximum: UInt64
      let fraction: Double
      let text: String
      let missing: String?
      let nested: [String: [Bool]]
    }
    // This heterogeneous fixture represents the existing ObjC recording seam.
    let fields: [String: Any] = [
      "enabled": NSNumber(value: true), "zero": NSNumber(value: 0), "one": 1,
      "minimum": Int64.min, "maximum": UInt64.max, "fraction": 0.125,
      "text": "caller/é\nsecond line", "missing": NSNull(),
      "nested": ["flags": [true, false]],
    ]
    let values = try fields.mapValues(RuntimeJournalValue.init(legacyValue:))
    let bytes = try JSONEncoder().encode(values)
    let result = try JSONDecoder().decode(Fields.self, from: bytes)
    #expect(result.enabled)
    #expect(result.zero == 0)
    #expect(result.one == 1)
    #expect(result.minimum == Int64.min)
    #expect(result.maximum == UInt64.max)
    #expect(result.fraction == 0.125)
    #expect(result.text == "caller/é\nsecond line")
    #expect(result.missing == nil)
    #expect(result.nested == ["flags": [true, false]])
    let decoded = try JSONDecoder().decode([String: RuntimeJournalValue].self, from: bytes)
    let roundTrip = try JSONDecoder().decode(Fields.self, from: JSONEncoder().encode(decoded))
    #expect(roundTrip.maximum == UInt64.max)
    #expect(roundTrip.nested == ["flags": [true, false]])
  }

  @Test func unsupportedLegacyFieldDoesNotWriteOrConsumeSequence() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    var writer = RuntimeJournalWriter()
    #expect(throws: RuntimeJournalValue.ConversionError.self) {
      try writer.append(to: file) { _ in
        try RuntimeJournalValue(legacyValue: ["nested": [NSObject()]])
      }
    }
    #expect(writer.sequence == 0)
    #expect(try Data(contentsOf: url).isEmpty)
    try writer.append(to: file) { Entry(sequence: $0, value: 42) }
    #expect(writer.sequence == 1)
  }
}
