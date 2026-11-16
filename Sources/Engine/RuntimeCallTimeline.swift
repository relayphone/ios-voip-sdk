#if os(macOS) || (os(iOS) && targetEnvironment(simulator))
  import Foundation
  #if SWIFT_PACKAGE
    import CKSimProtocol
  #endif

  struct RuntimeCallTimeline {
    private(set) var calls: [UUID: RetainedCall] = [:]
    mutating func beginIfEnded(_ uuid: UUID) {
      if calls[uuid]?.state == .ended { calls.removeValue(forKey: uuid) }
    }
    func isAwaitingAnswer(_ uuid: UUID) -> Bool {
      guard let call = calls[uuid] else { return false }
      return call.answeredAtMS == nil && call.endedAtMS == nil
    }
    mutating func update(
      _ uuid: UUID, now: UInt64, reported: Bool = true, _ change: (inout RetainedCall) -> Void
    ) {
      var call =
        calls[uuid] ?? RetainedCall(uuid: uuid, state: .ringing, reportedAtMS: reported ? now : nil)
      change(&call)
      calls[uuid] = call
      let ended = calls.values.filter { $0.state == .ended }.sorted {
        ($0.endedAtMS ?? 0, $0.uuid.uuidString) < ($1.endedAtMS ?? 0, $1.uuid.uuidString)
      }
      // Keep every live call and at most 256 ended calls for this invocation.
      for old in ended.prefix(max(0, ended.count - 256)) { calls.removeValue(forKey: old.uuid) }
    }
    /// Only a report for a known live call can confirm a video transition.
    mutating func confirmVideo(_ uuid: UUID, hasVideo: Bool, now: UInt64) -> RetainedCall
      .VideoChange?
    {
      guard var call = calls[uuid], call.state != .ended, call.hasVideo != hasVideo else {
        return nil
      }
      let change = RetainedCall.VideoChange(atMS: now, hasVideo: hasVideo)
      call.hasVideo = hasVideo
      call.videoChanges.append(change)
      calls[uuid] = call
      return change
    }
    static func answerDelay(rangAtMS: UInt64, nowMS: UInt64, afterMS: Int) -> Duration {
      let due = rangAtMS + UInt64(afterMS)
      return .milliseconds(due > nowMS ? due - nowMS : 0)
    }
  }
#endif
