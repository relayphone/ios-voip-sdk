import Foundation

/// Only metadata LCK cannot read back. Manager membership and state stay authoritative.
struct ConversationRecord {
  var direction: ConversationDirection
  var members: [Participant]
  var capabilities: ConversationCapabilities
  var video: Bool
  var muted = false
  var connecting = false
  var connectedAt: Date?
  var ended: ConversationEnded?
  var payload: IncomingCallPayload?
  var seenInManager = false
  var metadataIsPlaceholder = false

  /// LCK may announce an idle conversation before delivering its system start action.
  mutating func enrichSystemStart(members: [Participant], video: Bool) {
    guard metadataIsPlaceholder else { return }
    direction = .outgoing
    self.members = members
    self.video = video
    metadataIsPlaceholder = false
  }
}
