#if canImport(LiveCommunicationKit) && (os(iOS) || os(watchOS))
import Foundation
@preconcurrency import LiveCommunicationKit

/// Narrow interop boundary for Apple's non-actor-isolated incoming-report API.
/// The manager is the client's existing instance, created/configured on MainActor.
/// This wrapper assumes only that this async report operation may be invoked from
/// PushKit's worker. It does not declare the framework manager generally Sendable
/// or move any other manager operation away from the SDK actor.
final class IncomingReportTransport: @unchecked Sendable {
  private let manager: ConversationManager
  init(manager: ConversationManager) { self.manager = manager }

  func report(_ reservation: IncomingIntake.Reservation) async -> IncomingIntake.ReportOutcome {
    let caller = reservation.payload.caller
    let handle: Handle
    switch caller.handleType {
    case .phone: handle = Handle(type: .phoneNumber, value: caller.value, displayName: caller.displayName)
    case .email: handle = Handle(type: .emailAddress, value: caller.value, displayName: caller.displayName)
    case .generic: handle = Handle(type: .generic, value: caller.value, displayName: caller.displayName)
    }
    var capabilities: Conversation.Capabilities = [.pausing, .playingTones]
    if reservation.payload.hasVideo { capabilities.insert(.video) }
    let update = Conversation.Update(members: [handle], capabilities: capabilities)
    #if os(iOS) && targetEnvironment(simulator)
    SimulatorSupport.associateIncomingReport(reservation.id)
    defer { SimulatorSupport.finishIncomingReport(reservation.id) }
    #endif
    do {
      try await manager.reportNewIncomingConversation(uuid: reservation.id, update: update)
      return .reported
    } catch {
      return ConversationSystemErrors.isAlreadyReported(error) ? .alreadyReported(error) : .failed(error)
    }
  }
}
#endif
