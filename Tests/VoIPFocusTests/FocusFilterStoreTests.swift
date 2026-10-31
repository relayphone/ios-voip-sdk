import Foundation
import Testing

@testable import VoIPFocus

/// Recording and reading the Focus filter state, on storage that the test controls and a wall
/// clock that stands still.
@Suite struct FocusFilterStoreTests {
  let storage = FakeStorage()
  let dates = TestDates()
  let store: FocusFilterStore<CallSettings>

  init() {
    store = FocusFilterStore(storage: storage, now: { [dates] in dates.now })
  }

  // MARK: Unknown

  @Test func isUnknownUntilTheFilterFirstRuns() {
    #expect(store.state == .unknown)
  }

  @Test(arguments: [
    "",
    "not JSON",
    #"{"state":"active","since":1761948000,"settings":{"volume":0.5}}"#,
  ])
  func isUnknownWhenTheStateCannotBeRead(_ json: String) {
    storage.writeFromAnotherProcess(json)
    #expect(store.state == .unknown)
  }

  // MARK: Defaults mean inactive

  @Test func filterAtItsDefaultsIsInactive() throws {
    let state = try store.record(CallSettings(), defaults: CallSettings())
    #expect(state == .inactive(since: TestDates.start))
    #expect(store.state == state)
  }

  @Test func filterThatAsksForOtherSettingsIsActive() throws {
    let favorites = CallSettings(ringing: .favorites)
    let state = try store.record(favorites, defaults: CallSettings())
    #expect(state == .active(favorites, since: TestDates.start))
    #expect(store.state == state)
  }

  @Test func focusThatTurnsOffResetsTheFilterToInactive() throws {
    try store.record(CallSettings(ringing: .nobody), defaults: CallSettings())
    dates.advance(bySeconds: 3600)
    let state = try store.record(CallSettings(), defaults: CallSettings())
    #expect(state == .inactive(since: TestDates.start.addingTimeInterval(3600)))
    #expect(store.state == state)
  }

  @Test func otherSettingsReplaceTheActiveOnes() throws {
    try store.record(CallSettings(ringing: .nobody), defaults: CallSettings())
    dates.advance(bySeconds: 60)
    let favorites = CallSettings(ringing: .favorites)
    let state = try store.record(favorites, defaults: CallSettings())
    #expect(state == .active(favorites, since: TestDates.start.addingTimeInterval(60)))
  }

  @Test(arguments: [CallSettings(), CallSettings(ringing: .favorites)])
  func runningAgainWithTheSameSettingsKeepsTheEarlierState(_ settings: CallSettings) throws {
    let first = try store.record(settings, defaults: CallSettings())
    dates.advance(bySeconds: 600)
    let again = try store.record(settings, defaults: CallSettings())
    #expect(again == first)
    #expect(store.state == first)
    #expect(storage.writes == 1)
  }

  @Test func recordedStateIsTheOneThatEveryReaderDecodes() throws {
    // A date finer than a JSON number of Unix seconds keeps.
    let since = Date(timeIntervalSinceReferenceDate: 783_640_800.123_456_789)
    let store = FocusFilterStore<CallSettings>(storage: storage, now: { since })
    let state = try store.record(CallSettings(ringing: .favorites), defaults: CallSettings())
    #expect(state == store.state)
  }

  // MARK: Errors

  @Test func withoutTheAppGroupItRecordsNothing() {
    let store = FocusFilterStore<CallSettings>(storage: UnavailableStorage(), now: { Date() })
    #expect(throws: FocusFilterStoreError.appGroupUnavailable) {
      try store.record(CallSettings(ringing: .nobody), defaults: CallSettings())
    }
    #expect(store.state == .unknown)
  }

  @Test func settingsThatCannotBeEncodedAreNotRecorded() {
    let storage = FakeStorage()
    let store = FocusFilterStore<UnencodableSettings>(storage: storage, now: { Date() })
    #expect(throws: FocusFilterStoreError.encodingFailed) {
      try store.record(UnencodableSettings(volume: .nan), defaults: UnencodableSettings(volume: 1))
    }
    #expect(storage.writes == 0)
    #expect(store.state == .unknown)
  }

  @Test func settingsThatDoNotDecodeFromTheirJSONAreNotRecorded() {
    let storage = FakeStorage()
    let store = FocusFilterStore<OneWaySettings>(storage: storage, now: { Date() })
    #expect(throws: FocusFilterStoreError.encodingFailed) {
      try store.record(OneWaySettings(), defaults: OneWaySettings(isDefault: true))
    }
    #expect(storage.writes == 0)
  }

  // MARK: States

  @Test func streamStartsWithTheCurrentState() async throws {
    try store.record(CallSettings(ringing: .favorites), defaults: CallSettings())
    var states = store.states().makeAsyncIterator()
    #expect(await states.next() == .active(CallSettings(ringing: .favorites), since: dates.now))
  }

  @Test func streamFollowsEachRecordedChange() async throws {
    var states = store.states().makeAsyncIterator()
    #expect(await states.next() == .unknown)

    try store.record(CallSettings(ringing: .nobody), defaults: CallSettings())
    #expect(await states.next() == .active(CallSettings(ringing: .nobody), since: dates.now))

    dates.advance(bySeconds: 1800)
    try store.record(CallSettings(), defaults: CallSettings())
    #expect(await states.next() == .inactive(since: dates.now))
  }

  @Test func streamFollowsAnotherProcesssChange() async {
    var states = store.states().makeAsyncIterator()
    #expect(await states.next() == .unknown)

    storage.writeFromAnotherProcess(
      #"{"state":"active","since":1761948000,"settings":{"ringing":"favorites"}}"#)
    #expect(await states.next() == .active(CallSettings(ringing: .favorites), since: dates.now))
  }

  @Test func streamSkipsSignalsThatChangeNothing() async throws {
    var states = store.states().makeAsyncIterator()
    #expect(await states.next() == .unknown)

    storage.signalWithoutChange()
    try store.record(CallSettings(ringing: .nobody), defaults: CallSettings())
    dates.advance(bySeconds: 5)
    try store.record(CallSettings(ringing: .nobody), defaults: CallSettings())
    storage.signalWithoutChange()
    try store.record(CallSettings(), defaults: CallSettings())

    #expect(await states.next() == .active(CallSettings(ringing: .nobody), since: TestDates.start))
    #expect(await states.next() == .inactive(since: dates.now))
  }

  @Test func streamThatEndsStopsFollowing() async {
    var states: AsyncStream<FocusFilterState<CallSettings>>? = store.states()
    #expect(storage.subscribers == 1)
    _ = states
    states = nil
    #expect(storage.subscribers == 0)
  }

  @Test func eachStreamFollowsOnItsOwn() async throws {
    var first = store.states().makeAsyncIterator()
    #expect(await first.next() == .unknown)
    try store.record(CallSettings(ringing: .favorites), defaults: CallSettings())

    var second = store.states().makeAsyncIterator()
    let favorites = FocusFilterState.active(CallSettings(ringing: .favorites), since: dates.now)
    #expect(await second.next() == favorites)
    #expect(await first.next() == favorites)
    #expect(storage.subscribers == 2)
  }
}
