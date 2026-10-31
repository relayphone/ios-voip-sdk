import AppIntents
import Foundation
import Synchronization
import Testing

@testable import VoIPFocus

/// A Focus filter's default `perform()`, called as the system calls it when a Focus turns on or
/// off.
@Suite struct CallFocusFilterTests {
  let context = TestFilter.Context()

  /// Runs the filter with these parameters, as the system runs it.
  private func run(ringing: CallSettings.Ringing) async throws {
    let filter = TestFilter()
    filter.ringing = ringing
    try await TestFilter.$context.withValue(context) {
      _ = try await filter.perform()
    }
  }

  @Test func focusThatTurnsOnRecordsTheSettingsItAsksFor() async throws {
    try await run(ringing: .favorites)
    let favorites = FocusFilterState.active(
      CallSettings(ringing: .favorites), since: TestDates.start)
    #expect(context.store.state == favorites)
    #expect(context.recorded == [favorites])
  }

  @Test func focusThatTurnsOffRecordsInactive() async throws {
    try await run(ringing: .nobody)
    context.dates.advance(bySeconds: 3600)
    try await run(ringing: .everyone)
    let inactive = FocusFilterState<CallSettings>.inactive(
      since: TestDates.start.addingTimeInterval(3600))
    #expect(context.store.state == inactive)
    #expect(context.recorded.last == inactive)
  }

  @Test func focusThatKeepsEveryDefaultIsInactive() async throws {
    try await run(ringing: .everyone)
    #expect(context.store.state == .inactive(since: TestDates.start))
  }

  @Test func runningAgainHandsTheEarlierStateToTheApp() async throws {
    try await run(ringing: .favorites)
    context.dates.advance(bySeconds: 60)
    try await run(ringing: .favorites)
    let favorites = FocusFilterState.active(
      CallSettings(ringing: .favorites), since: TestDates.start)
    #expect(context.recorded == [favorites, favorites])
  }

  @Test func filterWithoutTheAppGroupThrowsAndHandsNothingToTheApp() async {
    let context = TestFilter.Context(storage: UnavailableStorage())
    await #expect(throws: FocusFilterStoreError.appGroupUnavailable) {
      try await TestFilter.$context.withValue(context) {
        _ = try await TestFilter().perform()
      }
    }
    #expect(context.recorded.isEmpty)
  }
}

extension CallSettings.Ringing: AppEnum {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Ring for"
  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .everyone: "Everyone", .favorites: "Favorites", .nobody: "Nobody",
  ]
}

/// A calling app's Focus filter, with a store and a record of `didRecord(_:)` that each test binds
/// for itself.
struct TestFilter: CallFocusFilter {
  /// One test's store, clock and the states the filter handed to the app.
  final class Context: Sendable {
    let dates = TestDates()
    let store: FocusFilterStore<CallSettings>
    private let states = Mutex<[FocusFilterState<CallSettings>]>([])

    init(storage: any StateStorage = FakeStorage()) {
      store = FocusFilterStore(storage: storage, now: { [dates] in dates.now })
    }

    var recorded: [FocusFilterState<CallSettings>] {
      states.withLock { $0 }
    }

    func append(_ state: FocusFilterState<CallSettings>) {
      states.withLock { $0.append(state) }
    }
  }

  @TaskLocal static var context = Context()

  static let title: LocalizedStringResource = "Incoming calls"

  static var store: FocusFilterStore<CallSettings> { context.store }

  @Parameter(title: "Ring for", default: .everyone)
  var ringing: CallSettings.Ringing

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "Ring for \(ringing.rawValue)")
  }

  var settings: CallSettings { CallSettings(ringing: ringing) }

  func didRecord(_ state: FocusFilterState<CallSettings>) async {
    Self.context.append(state)
  }
}
