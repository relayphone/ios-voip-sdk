#if SWIFT_PACKAGE
  import VoIPCore
#endif

/// What a call notification's `userInfo` carries, under one key, so that the user's response can
/// be routed in a later launch of the app.
///
/// It holds property-list values only: strings, booleans, arrays and dictionaries.
struct CallNotificationPayload: Hashable {
  /// The `userInfo` key under which the payload's dictionary is kept.
  static let key = "callNotification"

  var callID: CallID
  var caller: Party
  var hasVideo: Bool

  init(callID: CallID, caller: Party, hasVideo: Bool) {
    self.callID = callID
    self.caller = caller
    self.hasVideo = hasVideo
  }

  init(_ notification: CallNotification) {
    self.init(
      callID: notification.callID, caller: notification.caller, hasVideo: notification.hasVideo)
  }

  /// Reads the payload from a notification's `userInfo`, or returns `nil` when it holds none or an
  /// unreadable one.
  init?(userInfo: [AnyHashable: Any]) {
    guard let fields = userInfo[Self.key] as? [String: Any],
      let callID = fields["callID"] as? String,
      let entries = fields["handles"] as? [[String: String]]
    else { return nil }
    var handles: [Handle] = []
    for entry in entries {
      guard let kind = entry["kind"].flatMap(Handle.Kind.init(name:)), let value = entry["value"],
        let handle = try? Handle(kind: kind, value: value)
      else { return nil }
      handles.append(handle)
    }
    guard
      let caller = try? Party(handles: handles, displayName: fields["displayName"] as? String)
    else { return nil }
    self.init(
      callID: CallID(rawValue: callID), caller: caller,
      hasVideo: fields["hasVideo"] as? Bool ?? false)
  }

  /// The payload as `userInfo` entries.
  var userInfo: [AnyHashable: Any] {
    var fields: [String: Any] = [
      "callID": callID.rawValue,
      "handles": caller.handles.map { ["kind": $0.kind.name, "value": $0.value] },
      "hasVideo": hasVideo,
    ]
    if let displayName = caller.displayName { fields["displayName"] = displayName }
    return [Self.key: fields]
  }
}

extension Handle.Kind {
  /// The kind's name in a notification's `userInfo`.
  fileprivate var name: String {
    switch self {
    case .phoneNumber: "phoneNumber"
    case .emailAddress: "emailAddress"
    case .generic: "generic"
    }
  }

  fileprivate init?(name: String) {
    guard let kind = Self.allCases.first(where: { $0.name == name }) else { return nil }
    self = kind
  }
}

extension CallNotificationResponse {
  /// Reads a response from a call notification's `userInfo`, or returns `nil` for another
  /// notification.
  init?(userInfo: [AnyHashable: Any], action: Action) {
    guard let payload = CallNotificationPayload(userInfo: userInfo) else { return nil }
    self.init(
      callID: payload.callID, caller: payload.caller, hasVideo: payload.hasVideo, action: action)
  }
}
