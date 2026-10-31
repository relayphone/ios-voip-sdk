public import Foundation

#if SWIFT_PACKAGE
  public import VoIPCore
#endif
#if os(iOS)
  public import ActivityKit
#endif

/// The attributes of a call preview's Live Activity: the call that it previews, which doesn't
/// change while the Live Activity runs.
///
/// The SDK defines the attributes so that the app's servers can start a call preview with a
/// push-to-start token, and update or end it with the Live Activity's push token. Their JSON,
/// and that of ``ContentState``, is a contract between the SDK and the servers: a push names the
/// type as `"attributes-type": "CallPreviewAttributes"`, and the system decodes `attributes`
/// and `content-state` with these types.
///
/// ```json
/// {
///   "aps": {
///     "timestamp": 1800000000,
///     "event": "start",
///     "input-push-token": 1,
///     "stale-date": 1800000120,
///     "attributes-type": "CallPreviewAttributes",
///     "attributes": {
///       "callId": "call-1",
///       "parties": [{ "handleType": "phone", "value": "+14155550123", "displayName": "Alice" }],
///       "hasVideo": false,
///       "metadata": { "room": "room-1" }
///     },
///     "content-state": {
///       "status": "filtered",
///       "startedAt": 1799999990,
///       "statusText": "Your assistant is answering",
///       "isJoinable": true
///     },
///     "alert": { "title": "Alice", "body": "Call in progress" }
///   }
/// }
/// ```
///
/// In `attributes`:
///
/// - `callId`: the call's `CallID`, a string with a non-whitespace character.
/// - `parties`: the parties on the other side of the call, possibly none. Each is written like
///   the caller of the SDK's default VoIP push: `handleType` is `phone`, `email` or `generic`,
///   `value` is the handle, and `displayName` is optional. A phone number may contain spaces,
///   parentheses, hyphens and periods, which are removed; it must then be in E.164 format. A
///   party with more handles lists them in `additionalHandles`, each with `handleType` and
///   `value`.
/// - `hasVideo`: whether the call includes video. Optional; defaults to `false`.
/// - `metadata`: an object of any JSON values, which joining the call passes on as the call's
///   `metadata`. Optional; defaults to an empty object.
///
/// ``ContentState`` describes `content-state`. Dates are Unix timestamps in seconds, like the
/// push's `timestamp`, `stale-date` and `dismissal-date`.
///
/// The system limits the attributes and the content state together to 4 KB, so keep `metadata`
/// small. A push names the type without its module, so the contract holds whether the app
/// installs the SDK with Swift Package Manager or CocoaPods. The SDK's repository describes every
/// payload in `docs/call-preview-activity.md`, with fixtures in
/// `docs/contracts/call-preview-activity.json`.
public struct CallPreviewAttributes: Hashable, Sendable {
  /// The app's identifier for the call that the Live Activity previews.
  public var callID: CallID

  /// The parties on the other side of the call. The preview shows the first.
  public var parties: [Party]

  /// Whether the call includes video.
  public var hasVideo: Bool

  /// Values the app attached to the call, which joining the call from its preview passes on as
  /// the call's `metadata`.
  public var metadata: [String: JSONValue]

  /// Creates the attributes of a call preview's Live Activity.
  ///
  /// - Parameters:
  ///   - callID: The app's identifier for the call.
  ///   - parties: The parties on the other side of the call. The preview shows the first.
  ///   - hasVideo: Whether the call includes video.
  ///   - metadata: Values the app attached to the call.
  public init(
    callID: CallID, parties: [Party], hasVideo: Bool = false, metadata: [String: JSONValue] = [:]
  ) {
    self.callID = callID
    self.parties = parties
    self.hasVideo = hasVideo
    self.metadata = metadata
  }

  /// Creates the attributes of a Live Activity that previews a call.
  ///
  /// - Parameter call: The call to preview.
  public init(_ call: Call) {
    self.init(
      callID: call.id, parties: call.parties, hasVideo: call.hasVideo, metadata: call.metadata)
  }
}

extension CallPreviewAttributes {
  /// The state of a call preview's Live Activity, which the app or its servers update while the
  /// call continues.
  ///
  /// Its JSON is the `content-state` of a Live Activity push:
  ///
  /// ```json
  /// {
  ///   "status": "filtered",
  ///   "startedAt": 1799999990,
  ///   "statusText": "Your assistant is answering",
  ///   "snippet": "I'll let them know you called.",
  ///   "isJoinable": true
  /// }
  /// ```
  ///
  /// - `status`: a ``CallPreviewStatus`` raw value: `filtered`, `answeredElsewhere`, `policy`
  ///   or `ended`.
  /// - `startedAt`: when the call started, as a Unix timestamp in seconds, which may have a
  ///   fraction. The preview's timer counts from it.
  /// - `statusText`: optional; the app's words for what is happening.
  /// - `snippet`: optional; the latest line of a transcript or summary. Longer text is shortened
  ///   to ``maximumSnippetLength`` characters.
  /// - `isJoinable`: whether the preview offers Join.
  ///
  /// Dates are Unix timestamps rather than `Date`'s default `Codable` form, the seconds since
  /// 2001, so that servers write them as they write the push's `timestamp`. The type encodes and
  /// decodes them itself, so the system's default JSON decoding strategies read them correctly.
  public struct ContentState: Hashable, Sendable {
    /// The most characters that ``snippet`` holds: 240.
    public static let maximumSnippetLength = 240

    /// What is happening to the call.
    public var status: CallPreviewStatus

    /// When the call started. The preview's timer counts from it.
    public var startedAt: Date

    /// The app's words for what is happening, such as "Your assistant is answering", which the
    /// preview shows instead of describing ``status``.
    public var statusText: String?

    /// The latest line of the call's transcript or summary, if the app shows one.
    ///
    /// Text longer than ``maximumSnippetLength`` characters is shortened to that length, ending
    /// with an ellipsis.
    public var snippet: String? {
      get { storedSnippet }
      set { storedSnippet = newValue.map(Self.shortened) }
    }

    /// Whether the user can join the call from the preview, which then shows Join.
    public var isJoinable: Bool

    private var storedSnippet: String?

    /// Creates the state of a call preview's Live Activity.
    ///
    /// - Parameters:
    ///   - status: What is happening to the call.
    ///   - startedAt: When the call started.
    ///   - statusText: The app's words for what is happening.
    ///   - snippet: The latest line of the call's transcript or summary, shortened to
    ///     ``maximumSnippetLength`` characters.
    ///   - isJoinable: Whether the user can join the call from the preview.
    public init(
      status: CallPreviewStatus, startedAt: Date, statusText: String? = nil,
      snippet: String? = nil, isJoinable: Bool
    ) {
      self.status = status
      self.startedAt = startedAt
      self.statusText = statusText
      self.storedSnippet = snippet.map(Self.shortened)
      self.isJoinable = isJoinable
    }

    private static func shortened(_ text: String) -> String {
      guard text.count > maximumSnippetLength else { return text }
      return text.prefix(maximumSnippetLength - 1) + "…"
    }
  }
}

/// What is happening to a call that a Live Activity previews.
///
/// Its raw value is the `status` of the Live Activity's JSON content state.
public enum CallPreviewStatus: String, Hashable, Sendable, CaseIterable, Codable {
  /// The system filtered the call because of the user's Do Not Disturb, Focus or block list.
  case filtered
  /// The call was answered on another of the user's devices, or by a service acting for the user.
  case answeredElsewhere
  /// The app's presentation policy shows the call as a preview, for example while an assistant
  /// handles it.
  case policy
  /// The call ended.
  case ended

  /// Creates the status of a call preview from a call's status.
  ///
  /// - Parameter status: The call's status.
  /// - Returns: The preview's status, or `nil` for a call that isn't a call preview and hasn't
  ///   ended.
  public init?(_ status: CallStatus) {
    switch status {
    case .previewing(.filtered): self = .filtered
    case .previewing(.answeredElsewhere): self = .answeredElsewhere
    case .previewing(.policy): self = .policy
    case .ended: self = .ended
    case .ringing, .dialing, .connecting, .connected, .reconnecting: return nil
    }
  }
}

#if os(iOS)
  extension CallPreviewAttributes: ActivityAttributes {}
#endif
