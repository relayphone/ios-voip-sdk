import Foundation
import Testing
import VoIPFocus

/// The state's JSON, which apps send to their servers.
@Suite struct FocusFilterStateTests {
  typealias State = FocusFilterState<CallSettings>

  /// A state and its JSON object, with sorted keys.
  struct Fixture: Sendable, CustomTestStringConvertible {
    let state: State
    let json: String

    var testDescription: String { json }
  }

  static let fixtures = [
    Fixture(state: .unknown, json: #"{"state":"unknown"}"#),
    Fixture(
      state: .inactive(since: TestDates.start),
      json: #"{"since":1761948000,"state":"inactive"}"#),
    Fixture(
      state: .active(CallSettings(ringing: .favorites), since: TestDates.start),
      json: #"{"settings":{"ringing":"favorites"},"since":1761948000,"state":"active"}"#),
    Fixture(
      state: .active(CallSettings(ringing: .nobody), since: Date(timeIntervalSince1970: 1.5)),
      json: #"{"settings":{"ringing":"nobody"},"since":1.5,"state":"active"}"#),
  ]

  private func encode(_ state: State) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return String(decoding: try encoder.encode(state), as: UTF8.self)
  }

  private func decode(_ json: String) throws -> State {
    try JSONDecoder().decode(State.self, from: Data(json.utf8))
  }

  @Test(arguments: fixtures)
  func encodesAsItsJSONObject(_ fixture: Fixture) throws {
    #expect(try encode(fixture.state) == fixture.json)
  }

  @Test(arguments: fixtures)
  func decodesFromItsJSONObject(_ fixture: Fixture) throws {
    #expect(try decode(fixture.json) == fixture.state)
  }

  @Test func ignoresKeysItDoesNotKnow() throws {
    let state = try decode(#"{"state":"inactive","since":1761948000,"revision":4}"#)
    #expect(state == .inactive(since: TestDates.start))
  }

  @Test(arguments: [
    #"{}"#,
    #"{"state":"on","since":1761948000}"#,
    #"{"state":"inactive"}"#,
    #"{"state":"inactive","since":"yesterday"}"#,
    #"{"state":"active","since":1761948000}"#,
    #"{"state":"active","since":1761948000,"settings":{"ringing":"sometimes"}}"#,
  ])
  func rejectsObjectsThatAreNotAState(_ json: String) {
    #expect(throws: DecodingError.self) { try decode(json) }
  }
}
