import AppIntents
import ExtensionFoundation
import VoIPFocus

/// The App Intents extension in which the system runs the Focus filter, without launching the app.
@main
struct FocusFilterExtension: AppIntentsExtension {}

/// The example's Focus filter. In Settings > Focus, the user adds it to a Focus and picks which
/// calls ring while that Focus is on.
struct RingingFocusFilter: CallFocusFilter {
  static let title: LocalizedStringResource = "Incoming calls"
  static let description: IntentDescription? = "Choose which calls ring during this Focus."
  static let store = FocusSettings.store

  @Parameter(title: "Ring for", default: .everyone)
  var ringing: FocusSettings.Ringing

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "Ring for \(ringing.rawValue)")
  }

  var settings: FocusSettings {
    FocusSettings(ringing: ringing)
  }

  func didRecord(_ state: FocusFilterState<FocusSettings>) async {
    // Send the state to your servers here. They choose how each call appears on this device:
    // a VoIP push that rings, or a call preview.
  }
}

extension FocusSettings.Ringing: AppEnum {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Calls that ring"
  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .everyone: "Everyone",
    .favorites: "Favorites",
    .nobody: "Nobody",
  ]
}
