import VoIPFocus

/// What the example's Focus filter asks for in one Focus: which incoming calls ring this device.
/// The app and its Focus filter extension both compile this file.
struct FocusSettings: Codable, Hashable, Sendable {
  /// Which incoming calls ring this device.
  enum Ringing: String, CaseIterable, Codable, Hashable, Sendable {
    /// Every call rings, as outside a Focus.
    case everyone
    /// Calls from the user's favorites ring; the app's servers show the others as call previews.
    case favorites
    /// No call rings; the app's servers show every call as a call preview.
    case nobody
  }

  /// The default is the app's behaviour outside a Focus: every call rings.
  var ringing = Ringing.everyone
}

extension FocusSettings {
  /// The Focus filter state, in the App Group that the app and its Focus filter extension share.
  static let store = FocusFilterStore<FocusSettings>(appGroup: "group.com.example.CallExample")
}
