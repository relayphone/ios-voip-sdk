import AppIntents
import VoIPConversations

/// What the example's Focus filter asks for in one Focus: which incoming calls ring this device.
/// The module gives JavaScript these settings as JSON: `{ "ringing": "favorites" }`.
struct CallSettings: Codable, Hashable, Sendable {
  /// The default is what the app does outside a Focus: every call rings.
  var ringing = Ringing.everyone

  /// The Focus filter state, in the App Group of the plugin's `focusFilter.appGroup`.
  static let store = FocusFilterStore<CallSettings>(
    appGroup: "group.com.example.voipconversations")
}

/// Which incoming calls ring this device.
enum Ringing: String, Codable, Hashable, Sendable, AppEnum {
  case everyone
  case favorites
  case nobody

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Calls that ring"
  static let caseDisplayRepresentations: [Ringing: DisplayRepresentation] = [
    .everyone: "Everyone",
    .favorites: "Favorites",
    .nobody: "Nobody",
  ]
}

/// The example's Focus filter. In Settings > Focus, the user adds it to a Focus and picks which
/// calls ring while that Focus is on. The system runs it when that Focus turns on or off.
struct CallsFocusFilter: CallFocusFilter {
  static let title: LocalizedStringResource = "Incoming calls"
  static let description: IntentDescription? = "Choose which calls ring during this Focus."
  static let store = CallSettings.store

  @Parameter(title: "Ring for", default: .everyone)
  var ringing: Ringing

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "Ring for \(ringing.rawValue)")
  }

  var settings: CallSettings { CallSettings(ringing: ringing) }
}
