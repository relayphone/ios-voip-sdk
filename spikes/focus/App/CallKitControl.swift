import AVFoundation
import CallKit
import Foundation

// Instantiated instead of, never alongside, the LCK ConversationManager.
final class CallKitControl: NSObject, CXProviderDelegate, @unchecked Sendable {
  let provider: CXProvider
  private let lock = NSLock()
  private var answered: Set<UUID> = []
  private var active: Set<UUID> = []
  override init() {
    let configuration = CXProviderConfiguration()
    configuration.includesCallsInRecents = false
    configuration.maximumCallGroups = 1
    configuration.maximumCallsPerCallGroup = 1
    configuration.supportedHandleTypes = [.phoneNumber, .generic]
    provider = CXProvider(configuration: configuration)
    super.init()
    provider.setDelegate(self, queue: nil)
  }
  func report(id: UUID, caller: String, kind: String, ringTimeout: Double, completion: @escaping (Error?) -> Void) {
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: kind == "generic" ? .generic : .phoneNumber, value: caller)
    update.localizedCallerName = "Focus Test Caller"
    provider.reportNewIncomingCall(with: id, update: update) { error in
      if error == nil { self.lock.lock(); self.active.insert(id); self.lock.unlock() }
      completion(error)
      guard error == nil else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + ringTimeout) {
        self.lock.lock()
        let exists = self.active.remove(id) != nil
        let joined = self.answered.remove(id) != nil
        self.lock.unlock()
        guard exists else { return }
        self.provider.reportCall(with: id, endedAt: Date(), reason: joined ? .remoteEnded : .unanswered)
        Trace.shared.log("call.autoEnd", ["invitationID": id.uuidString, "answered": joined, "provider": "callkit"])
      }
    }
  }
  func providerDidReset(_ provider: CXProvider) {
    lock.lock(); answered.removeAll(); active.removeAll(); lock.unlock()
    Trace.shared.log("call.reset", ["provider": "callkit"])
  }
  // Returns false if the invitation has already ended or the local user answered.
  func answeredElsewhere(id: UUID) -> Bool {
    lock.lock()
    guard active.contains(id), !answered.contains(id) else { lock.unlock(); return false }
    active.remove(id)
    lock.unlock()
    provider.reportCall(with: id, endedAt: Date(), reason: .answeredElsewhere)
    return true
  }
  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    lock.lock()
    let stillActive = active.contains(action.callUUID)
    if stillActive { answered.insert(action.callUUID) }
    lock.unlock()
    Trace.shared.log("call.action", ["kind": "CXAnswerCallAction", "invitationID": action.callUUID.uuidString, "provider": "callkit"])
    if stillActive { action.fulfill() } else { action.fail() }
  }
  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    lock.lock(); answered.remove(action.callUUID); active.remove(action.callUUID); lock.unlock()
    Trace.shared.log("call.action", ["kind": "CXEndCallAction", "invitationID": action.callUUID.uuidString, "provider": "callkit"])
    action.fulfill()
  }
  func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) { Trace.shared.log("call.actionTimeout", ["provider": "callkit"]) }
  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) { Trace.shared.log("call.audioActivated", ["provider": "callkit"]) }
  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) { Trace.shared.log("call.audioDeactivated", ["provider": "callkit"]) }
}
