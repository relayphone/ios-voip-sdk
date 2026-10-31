import Foundation
import Observation
import VoIPCore
import VoIPLiveCommunicationKit
import VoIPPushKit
import VoIPSimulator

/// The app's real-time audio and video transport, such as WebRTC. This one does nothing.
@VoIPActor
final class NoMedia: CallMedia {
  nonisolated init() {}

  /// Connect to the call's room here, without using the microphone or speaker yet.
  func prepare(_ call: Call) async throws {}

  /// Start the microphone and speaker here: the system activated the audio session.
  func activate() {}

  /// Stop using the audio session here: the system deactivated it.
  func deactivate() {}
}

/// Starts the SDK when the app launches and turns the user's taps into actions.
@MainActor
@Observable
final class Calls {
  /// The SDK's client. Its `calls` hold every call that hasn't ended.
  let client: VoIPClient

  /// The VoIP push token, as hexadecimal, for the app's servers.
  private(set) var pushToken = "None yet"

  /// What happened to calls, newest first.
  private(set) var history: [String] = []

  init() {
    // In Debug simulator builds, this presents calls in the iOS Simulator. Elsewhere it does
    // nothing.
    VoIPSimulator.activate()
    let push = PushKitSource()
    do {
      client = try VoIPClient.start(
        framework: LiveCommunicationKitAdapter(), media: NoMedia(), push: push)
    } catch {
      fatalError("A process runs one VoIPClient: \(error)")
    }
    Task { [weak self] in
      // Send each token to your servers, which send this device's VoIP pushes.
      for await token in push.tokens() {
        self?.pushToken = token?.map { String(format: "%02x", $0) }.joined() ?? "Invalidated"
      }
    }
    let events = client.events()
    Task { [weak self] in
      for await event in events { await self?.handle(event) }
    }
  }

  /// Presents an incoming call, as a VoIP push from the app's servers would.
  func reportIncomingCall() async {
    do {
      let caller = Party(
        handle: try Handle(kind: .phoneNumber, value: "+14155550123"), displayName: "Alice")
      let call = IncomingCall(id: CallID(rawValue: UUID().uuidString), parties: [caller])
      let outcome = await client.report(call)
      history.insert("Reported: \(outcome)", at: 0)
    } catch {
      history.insert("Invalid caller: \(error)", at: 0)
    }
  }

  /// Asks the SDK to answer, end, mute or unmute a call.
  func request(_ action: Action) async {
    do {
      try await client.request(action)
    } catch {
      history.insert("Refused: \(error)", at: 0)
    }
  }

  private func handle(_ event: CallEvent) async {
    switch event {
    case .presented(let call): history.insert("Ringing: \(call.id.rawValue)", at: 0)
    case .previewStarted(let call): history.insert("Previewing: \(call.status)", at: 0)
    case .startRequested(let call), .joinRequested(let call):
      // The app places the call with its servers, then confirms it.
      await client.confirmPlaced(call.id)
    case .performed(let action, let call):
      history.insert("Performed \(action) → \(call.status)", at: 0)
      if case .answer(let id) = action {
        // Your servers tell the app when the call's media connects. This example connects at once.
        await client.receive(.connected, for: id, eventID: EventID(rawValue: UUID().uuidString))
      }
    case .audioActivated: history.insert("Audio activated", at: 0)
    case .audioDeactivated: history.insert("Audio deactivated", at: 0)
    case .ended(let call): history.insert("Ended: \(call.status)", at: 0)
    }
  }
}
