import CallKit
import Foundation
let id = UUID()
var actions: [(String, CXAction)] = [
  ("start", CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: "x"))),
  ("answer", CXAnswerCallAction(call: id)), ("end", CXEndCallAction(call: id)),
  ("held", CXSetHeldCallAction(call: id, onHold: true)), ("muted", CXSetMutedCallAction(call: id, muted: true)),
  ("group", CXSetGroupCallAction(call: id, callUUIDToGroupWith: nil)),
  ("dtmf", CXPlayDTMFCallAction(call: id, digits: "1", type: .singleTone)),
]
for name in ["CXSetTranslatingCallAction", "CXSetScreeningCallAction", "CXSetRelayingCallAction", "CXSetSendingVideoCallAction", "CXSetVideoPresentationStateCallAction", "CXJoinCallAction", "CXPullCallAction", "CXSetSharingScreenCallAction", "CXSetRecordingCallAction"] {
  print("class", name, NSClassFromString(name) != nil)
}
for (n, a) in actions { print("timeout", n, (a.timeoutDate.timeIntervalSinceNow).rounded()) }
