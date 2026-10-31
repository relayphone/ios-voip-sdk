import Foundation

#if SWIFT_PACKAGE
  import VoIPCore
#endif

/// What the default views of a call preview show, decided apart from SwiftUI so that the host's
/// tests cover it.
struct CallPreviewDisplay: Sendable {
  /// What is happening to the call.
  enum Status: Sendable {
    /// The app's words, shown as they are.
    case text(String)
    /// The SDK's description of the status.
    case described(LocalizedStringResource)
  }

  /// The name of the party: their display name, or the presented handle.
  let name: String?

  /// What is happening: the app's words, or a description of the status.
  let status: Status

  /// When the call started, for a timer, or `nil` once it ended.
  let timerStart: Date?

  /// The latest line of the transcript or summary, unless the state is out of date.
  let snippet: String?

  /// Whether to say that the state is out of date.
  let showsDelay: Bool

  /// Whether to offer Join.
  let showsJoin: Bool

  /// The name of the SF Symbol for the call: a phone, a video camera, or a phone hung up.
  let symbol: String

  init(
    attributes: CallPreviewAttributes, state: CallPreviewAttributes.ContentState, isStale: Bool
  ) {
    let party = attributes.parties.first
    name = party.map { $0.displayName ?? $0.presentedHandle.value }
    let isEnded = state.status == .ended
    if let text = state.statusText {
      status = .text(text)
    } else {
      status = .described(Self.describe(state.status))
    }
    timerStart = isEnded ? nil : state.startedAt
    showsDelay = isStale && !isEnded
    snippet = showsDelay ? nil : state.snippet
    showsJoin = state.isJoinable && !isEnded
    symbol = isEnded ? "phone.down.fill" : attributes.hasVideo ? "video.fill" : "phone.fill"
  }

  /// The words for a status, which the widget extension's Localizable strings can translate.
  private static func describe(_ status: CallPreviewStatus) -> LocalizedStringResource {
    switch status {
    case .filtered: "Call silenced"
    case .answeredElsewhere: "Answered on another device"
    case .policy: "Call in progress"
    case .ended: "Call ended"
    }
  }
}
