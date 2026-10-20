import AVFoundation
import CallKit
import SwiftUI
import WebRTC

// Real media through the canonical CallKit + WebRTC pattern: WebRTC audio stays
// disabled until provider(_:didActivate:), exactly as Telnyx, LiveKit and Twilio apps do.
func log(_ event: String, _ fields: [String: Any] = [:]) {
  var f = fields
  f["event"] = event
  f["t_ms"] = Int(Date().timeIntervalSince(MediaProbe.t0) * 1000)
  let data = (try? JSONSerialization.data(withJSONObject: f, options: [.sortedKeys])) ?? Data()
  FileHandle.standardError.write(Data("MEDIA ".utf8) + data + Data("\n".utf8))
}

final class PeerDelegate: NSObject, RTCPeerConnectionDelegate {
  let name: String
  var onCandidate: ((RTCIceCandidate) -> Void)?
  init(_ name: String) { self.name = name }
  func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
  func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
  func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
  func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
  func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) { log("ice", ["peer": name, "state": newState.rawValue]) }
  func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
  func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) { onCandidate?(candidate) }
  func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
  func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

final class MediaProbe: NSObject, CXProviderDelegate, @unchecked Sendable {
  static let t0 = Date()
  let provider: CXProvider
  let controller = CXCallController()
  let factory: RTCPeerConnectionFactory
  let delegateA = PeerDelegate("caller"), delegateB = PeerDelegate("callee")
  var caller: RTCPeerConnection!
  var callee: RTCPeerConnection!
  var track: RTCAudioTrack!
  let call = UUID()

  override init() {
    RTCInitializeSSL()
    let session = RTCAudioSession.sharedInstance()
    session.useManualAudio = true
    session.isAudioEnabled = false
    factory = RTCPeerConnectionFactory()
    let config = CXProviderConfiguration()
    config.supportedHandleTypes = [.generic]
    provider = CXProvider(configuration: config)
    super.init()
    provider.setDelegate(self, queue: nil)
  }

  func providerDidReset(_ provider: CXProvider) { log("provider.reset") }
  func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
    let session = RTCAudioSession.sharedInstance()
    session.lockForConfiguration()
    try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
    session.unlockForConfiguration()
    action.fulfill()
    provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
    log("start.fulfilled")
  }
  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    track.isEnabled = !action.isMuted
    action.fulfill()
    log("mute", ["muted": action.isMuted])
  }
  func provider(_ provider: CXProvider, perform action: CXEndCallAction) { action.fulfill(); log("end.fulfilled") }
  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
    RTCAudioSession.sharedInstance().isAudioEnabled = true
    log("didActivate")
  }
  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
    RTCAudioSession.sharedInstance().isAudioEnabled = false
    log("didDeactivate")
  }

  func sample(_ label: String) async {
    func stats(_ pc: RTCPeerConnection) async -> [String: RTCStatistics] {
      await withCheckedContinuation { c in pc.statistics { c.resume(returning: $0.statistics) } }
    }
    var f: [String: Any] = ["label": label]
    for s in (await stats(caller)).values {
      if s.type == "media-source" { f["src.energy"] = s.values["totalAudioEnergy"]; f["src.level"] = s.values["audioLevel"] }
      if s.type == "outbound-rtp" { f["out.packets"] = s.values["packetsSent"] }
    }
    for s in (await stats(callee)).values where s.type == "inbound-rtp" {
      f["in.packets"] = s.values["packetsReceived"]; f["in.energy"] = s.values["totalAudioEnergy"]
      f["in.samples"] = s.values["totalSamplesReceived"]; f["in.concealed"] = s.values["concealedSamples"]
    }
    log("stats", f)
  }

  func run() async {
    log("start", ["injected": ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"]?.contains("CKSim") ?? false])
    let config = RTCConfiguration()
    config.sdpSemantics = .unifiedPlan
    let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    caller = factory.peerConnection(with: config, constraints: constraints, delegate: delegateA)
    callee = factory.peerConnection(with: config, constraints: constraints, delegate: delegateB)
    delegateA.onCandidate = { [weak self] c in self?.callee.add(c) { _ in } }
    delegateB.onCandidate = { [weak self] c in self?.caller.add(c) { _ in } }
    track = factory.audioTrack(with: factory.audioSource(with: constraints), trackId: "mic")
    caller.add(track, streamIds: ["call"])
    do {
      let offer = try await caller.offer(for: constraints)
      try await caller.setLocalDescription(offer)
      try await callee.setRemoteDescription(offer)
      let answer = try await callee.answer(for: constraints)
      try await callee.setLocalDescription(answer)
      try await caller.setRemoteDescription(answer)
      log("negotiated")
    } catch { log("negotiation.failed", ["error": "\(error)"]); return }
    let delay = Double(ProcessInfo.processInfo.environment["MEDIA_START_DELAY"] ?? "0") ?? 0
    if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    let result: String = await withCheckedContinuation { c in
      controller.request(CXTransaction(action: CXStartCallAction(call: call, handle: CXHandle(type: .generic, value: "loopback")))) { err in
        c.resume(returning: err.map { "\(($0 as NSError).domain):\(($0 as NSError).code)" } ?? "ok")
      }
    }
    log("start.request", ["result": result])
    for i in 1...6 { try? await Task.sleep(nanoseconds: 1_000_000_000); await sample("live-\(i)") }
    controller.request(CXTransaction(action: CXSetMutedCallAction(call: call, muted: true))) { _ in }
    for i in 1...3 { try? await Task.sleep(nanoseconds: 1_000_000_000); await sample("muted-\(i)") }
    controller.request(CXTransaction(action: CXSetMutedCallAction(call: call, muted: false))) { _ in }
    for i in 1...3 { try? await Task.sleep(nanoseconds: 1_000_000_000); await sample("unmuted-\(i)") }
    controller.request(CXTransaction(action: CXEndCallAction(call: call))) { _ in }
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    caller.close(); callee.close()
    log("done")
  }
}

@main
struct MediaProbeApp: App {
  static let probe = MediaProbe()
  var body: some Scene { WindowGroup { Text("Media probe").task { await MediaProbeApp.probe.run() } } }
}
