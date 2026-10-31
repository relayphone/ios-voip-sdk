import AppIntents
import VoIPLiveActivity

/// The Join button of a call preview's Live Activity. The app and its widget extension both
/// compile this file: the widget shows the button, and the system performs the intent in the app.
struct JoinCall: JoinCallPreviewIntent {
  static let title: LocalizedStringResource = "Join Call"
  static let supportedModes: IntentModes = .foreground(.immediate)
  /// Only the Join button performs it: Shortcuts and Spotlight would ask for a call ID as text.
  static let isDiscoverable = false

  @Parameter(title: "Call ID")
  var callID: String
}
