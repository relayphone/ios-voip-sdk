public import AppIntents

/// The app's Focus filter, which records the Focus filter state each time the system runs it.
///
/// The user adds the filter to a Focus in Settings and chooses its parameters there. The system
/// runs it when that Focus turns on, and again when the Focus turns off, with every parameter
/// reset to its default. The filter's default `perform()` records what the parameters ask for in
/// ``store``: inactive when they equal their defaults, and active otherwise. Then it calls
/// ``didRecord(_:)``, where the app sends the state to its servers.
///
/// Declare the filter in the app's App Intents extension, so that the system runs it without
/// launching the app, and give the app and the extension the same App Group. Keep the settings and
/// the store in a file that both compile, so that the app reads the same state. The parameters and
/// the settings they make are the app's own:
///
/// ```swift
/// // In a file that the app and the extension both compile:
/// struct CallSettings: Codable, Hashable, Sendable {
///   var ringing = Ringing.everyone
///
///   static let store = FocusFilterStore<CallSettings>(appGroup: "group.com.example.calls")
/// }
///
/// // In the extension only:
/// struct CallsFocusFilter: CallFocusFilter {
///   static let title: LocalizedStringResource = "Incoming calls"
///   static let store = CallSettings.store
///
///   @Parameter(title: "Ring for", default: .everyone)
///   var ringing: Ringing
///
///   var displayRepresentation: DisplayRepresentation {
///     DisplayRepresentation(title: "Ring for \(ringing.rawValue)")
///   }
///
///   var settings: CallSettings { CallSettings(ringing: ringing) }
///
///   func didRecord(_ state: FocusFilterState<CallSettings>) async {
///     await server.updateFocusFilterState(state)
///   }
/// }
/// ```
///
/// Give every parameter a default, and make the defaults what the app does outside a Focus: a
/// Focus that turns off resets the filter to them, and a filter at its defaults is inactive. An
/// app has one Focus filter: App Intents allows one `SetFocusFilterIntent` type in a target.
public protocol CallFocusFilter: SetFocusFilterIntent {
  /// The app's settings for one Focus, such as which calls ring this device.
  associatedtype Settings: Codable & Hashable & Sendable

  /// The settings that the filter's parameters ask for.
  var settings: Settings { get }

  /// Where the filter records the Focus filter state: a store in the App Group that the app and
  /// the extension share.
  static var store: FocusFilterStore<Settings> { get }

  /// Called after the filter records the Focus filter state, in the process where the system ran
  /// the filter, usually the App Intents extension.
  ///
  /// Send the state to the app's servers here, so that they choose how each call appears on this
  /// device. The system may end the extension soon after the filter returns, so finish before
  /// returning. The default does nothing.
  ///
  /// - Parameter state: The state that the store holds now. When the filter already asked for the
  ///   same, it is the earlier state, with its date.
  func didRecord(_ state: FocusFilterState<Settings>) async
}

extension CallFocusFilter {
  /// Records what the filter's parameters ask for in ``store``, then calls ``didRecord(_:)``.
  ///
  /// The state is inactive when ``settings`` equal those of the filter with every parameter at its
  /// default, and active otherwise.
  ///
  /// - Returns: An empty result.
  /// - Throws: ``FocusFilterStoreError/appGroupUnavailable`` when this process doesn't belong to
  ///   the store's App Group, or ``FocusFilterStoreError/encodingFailed`` when the settings can't
  ///   be encoded as JSON.
  public func perform() async throws -> some IntentResult {
    let state = try Self.store.record(settings, defaults: Self().settings)
    await didRecord(state)
    return .result()
  }

  /// Does nothing.
  public func didRecord(_ state: FocusFilterState<Settings>) async {}
}
