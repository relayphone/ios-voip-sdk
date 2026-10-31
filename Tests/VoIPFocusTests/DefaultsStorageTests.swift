import Foundation
import Testing

@testable import VoIPFocus

/// The store on real `UserDefaults`, with the in-process signal and with Darwin notifications.
@Suite(.timeLimit(.minutes(1)))
struct DefaultsStorageTests {
  @Test func storeInUserDefaultsRecordsAndFollowsItsOwnChanges() async throws {
    try await withScratchDefaults { defaults, _ in
      let store = FocusFilterStore<CallSettings>(userDefaults: defaults)
      var states = store.states().makeAsyncIterator()
      #expect(await states.next() == .unknown)

      let state = try store.record(CallSettings(ringing: .favorites), defaults: CallSettings())
      #expect(await states.next() == state)
      #expect(store.state == state)
      #expect(defaults.data(forKey: DefaultsStorage.key) != nil)
    }
  }

  @Test func storesInTheSameDefaultsShareTheState() async throws {
    try await withScratchDefaults { defaults, _ in
      let filter = FocusFilterStore<CallSettings>(userDefaults: defaults)
      let app = FocusFilterStore<CallSettings>(userDefaults: defaults)
      let state = try filter.record(CallSettings(ringing: .nobody), defaults: CallSettings())
      #expect(app.state == state)
    }
  }

  /// Two storages with the same defaults and notification name stand in for the filter's
  /// extension and the app: a Darwin notification reaches every observer, in any process.
  @Test func darwinNotificationTellsTheOtherStoreOfAChange() async throws {
    try await withScratchDefaults { defaults, name in
      let signalName = "\(name).\(DefaultsStorage.key)"
      let filter = FocusFilterStore<CallSettings>(
        storage: DefaultsStorage(defaults: defaults, signal: DarwinSignal(name: signalName)),
        now: { TestDates.start })
      let app = FocusFilterStore<CallSettings>(
        storage: DefaultsStorage(defaults: defaults, signal: DarwinSignal(name: signalName)),
        now: { TestDates.start })

      var states = app.states().makeAsyncIterator()
      #expect(await states.next() == .unknown)

      try filter.record(CallSettings(ringing: .favorites), defaults: CallSettings())
      #expect(
        await states.next() == .active(CallSettings(ringing: .favorites), since: TestDates.start))
    }
  }
}
