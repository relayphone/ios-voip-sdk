#if SDK_DEVICE_QA
import Foundation
#if SWIFT_PACKAGE
import VoIPPlatform
#endif

/// Available only in the instrumented device fixture, never in normal SDK builds.
public struct SDKDeviceQARecord: Codable, Sendable {
  public enum Event: String, Codable, Sendable {
    case pushIngress = "push.ingress", pushCompletion = "push.completion"
    case receiverIngress = "push.receiverIngress", reportBegin = "report.begin", reportResult = "report.result"
    case actionIngress = "action.ingress", actionSettlement = "action.settlement"
    case audioActivated = "audio.activated", audioDeactivated = "audio.deactivated"
  }
  public enum PushAPI: String, Codable, Sendable { case metadata, legacy }
  public let event: Event
  public let nanoseconds: UInt64
  public let mainThread: Bool
  public let deliveryID: UUID?
  public let conversationID: UUID?
  public let actionID: UUID?
  public let actionKind: ConversationActionKind?
  public let api: PushAPI?
  public let mustReport: Bool?
  public let succeeded: Bool?
  public let errorDomain: String?
  public let errorCode: Int?
}

enum SDKDeviceQAPushContext {
  @TaskLocal static var deliveryID: UUID?
}

@MainActor
public enum SDKDeviceQADiagnostics {
  private static var sink: (@MainActor (SDKDeviceQARecord) -> Void)?
  public static func install(_ sink: @escaping @MainActor (SDKDeviceQARecord) -> Void) {
    self.sink = sink
    VSDeviceQASetObserver { @Sendable event, deliveryID, api, mustReport, nanoseconds, mainThread in
      guard let event = SDKDeviceQARecord.Event(rawValue: event),
            let api = SDKDeviceQARecord.PushAPI(rawValue: api) else { return }
      let record = SDKDeviceQARecord(event: event, nanoseconds: nanoseconds, mainThread: mainThread,
        deliveryID: deliveryID as UUID, conversationID: nil, actionID: nil, actionKind: nil,
        api: api, mustReport: mustReport, succeeded: nil, errorDomain: nil, errorCode: nil)
      if Thread.isMainThread { MainActor.assumeIsolated { Self.sink?(record) } }
      else { Task { @MainActor in Self.sink?(record) } }
    }
  }

  static func emit(_ event: SDKDeviceQARecord.Event,
                   deliveryID: UUID? = SDKDeviceQAPushContext.deliveryID,
                   conversationID: UUID? = nil, actionID: UUID? = nil,
                   actionKind: ConversationActionKind? = nil, mustReport: Bool? = nil,
                   succeeded: Bool? = nil, error: (any Error)? = nil) {
    let nativeError = error as NSError?
    let domain = nativeError.map { value in
      // Only categories escape; an arbitrary error domain can contain application data.
      if value.domain.hasPrefix("com.apple.CallKit") { return "CallKit" }
      if value.domain.hasPrefix("com.apple.LiveCommunicationKit") { return "LiveCommunicationKit" }
      if value.domain.hasPrefix("NS") { return "Foundation" }
      if value.domain.hasPrefix("VoIPSDK.") { return "VoIPSDK" }
      return "other"
    }
    sink?(SDKDeviceQARecord(event: event, nanoseconds: VSDeviceQANanoseconds(),
      mainThread: Thread.isMainThread, deliveryID: deliveryID, conversationID: conversationID,
      actionID: actionID, actionKind: actionKind, api: nil, mustReport: mustReport,
      succeeded: succeeded, errorDomain: domain, errorCode: nativeError?.code))
  }
}
#endif
