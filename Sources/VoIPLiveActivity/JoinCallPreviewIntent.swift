#if os(iOS)
  public import AppIntents

  #if SWIFT_PACKAGE
    public import VoIPCore
  #endif

  /// The intent of a call preview's Join button, which joins the call on this device.
  ///
  /// The system describes an app's intents from the App Intents metadata that Xcode extracts
  /// from the app's own types, so the SDK supplies the behaviour and the app declares the type.
  /// Declare one conforming type in a file that both the app and its widget extension compile:
  ///
  /// ```swift
  /// import AppIntents
  /// import VoIPLiveActivity
  ///
  /// struct JoinCall: JoinCallPreviewIntent {
  ///   static let title: LocalizedStringResource = "Join Call"
  ///   static let supportedModes: IntentModes = .foreground(.immediate)
  ///   static let isDiscoverable = false
  ///
  ///   @Parameter(title: "Call ID")
  ///   var callID: String
  /// }
  /// ```
  ///
  /// The widget extension passes the type to ``CallPreviewView``, whose Join button creates it
  /// with ``init(callID:)``. When the user taps Join, the system performs the intent in the app,
  /// and ``perform()`` joins the call with the ``CallPreviewActivities`` that the app passed to
  /// `VoIPClient.start`. On a locked device, the system asks the user to unlock first.
  ///
  /// Declare `supportedModes` as above, so that the system opens the app before it joins the
  /// call. A Live Activity's intent otherwise runs with the app in the background, and
  /// LiveCommunicationKit's documentation doesn't say that an app may start a call from there.
  /// Opening the app also shows the call as it starts.
  ///
  /// Declare `isDiscoverable` as `false` too, so that only the Join button performs the intent.
  /// Otherwise Shortcuts and Spotlight offer Join Call as one of the app's actions, asking the user
  /// for a call ID as free text.
  ///
  /// The metadata holds only what the type itself declares, so the SDK can't declare either for
  /// the app.
  public protocol JoinCallPreviewIntent: LiveActivityIntent {
    /// The raw value of the `CallID` of the call to join. Declare it as an `@Parameter`.
    var callID: String { get set }
  }

  extension JoinCallPreviewIntent {
    /// Creates the intent that joins a call.
    ///
    /// - Parameter callID: The call to join.
    public init(callID: CallID) {
      self.init()
      self.callID = callID.rawValue
    }

    /// Joins the call with the ``CallPreviewActivities`` that the app passed to
    /// `VoIPClient.start`.
    ///
    /// - Throws: A ``CallPreviewError`` when the call can't be joined, for example
    ///   ``CallPreviewError/notAttached`` when the app didn't start a client with the observer as
    ///   it launched.
    public func perform() async throws -> some IntentResult {
      try await CallPreviewActivities.join(CallID(rawValue: callID))
      return .result()
    }
  }
#endif
