import VoIPCore

@testable import VoIPAudio

/// An audio session that records what the adapter asks of it, with ports that the test sets, as
/// `AVAudioSession` reports them.
@VoIPActor
final class FakeSession: SessionControl {
  enum Record: Hashable {
    case setCategory(CategoryOptions)
    case overrideOutput(toSpeaker: Bool)
    case setPreferredInput(String)
  }

  private(set) var records: [Record] = []
  /// The available inputs and current outputs.
  var current = SessionPorts(inputs: [], outputs: [])
  var failsConfiguration = false
  var refusesRouteChanges = false

  nonisolated init() {}

  func setCategory(options: CategoryOptions) throws(AudioSessionError) {
    records.append(.setCategory(options))
    if failsConfiguration { throw .configurationFailed }
  }

  func ports() -> SessionPorts {
    current
  }

  func overrideOutput(toSpeaker: Bool) throws(AudioRouteError) {
    if refusesRouteChanges { throw .refused }
    records.append(.overrideOutput(toSpeaker: toSpeaker))
  }

  func setPreferredInput(uid: String) throws(AudioRouteError) {
    guard current.inputs.contains(where: { $0.uid == uid }) else { throw .unavailable }
    if refusesRouteChanges { throw .refused }
    records.append(.setPreferredInput(uid))
  }
}

/// A notification center that delivers the notifications the test posts, as the system's would.
@VoIPActor
final class FakeNotifications: SessionNotifications {
  private var receive: (@VoIPActor (SessionNotification) -> Void)?

  nonisolated init() {}

  func start(_ receive: @escaping @VoIPActor (SessionNotification) -> Void) {
    self.receive = receive
  }

  /// Delivers a notification to the adapter.
  func post(_ notification: SessionNotification) {
    guard let receive else { preconditionFailure("The adapter hasn't started observing") }
    receive(notification)
  }
}

/// An adapter on the fakes, attached as the SDK attaches it, with the events it sent.
@VoIPActor
final class Attached {
  let session = FakeSession()
  let notifications = FakeNotifications()
  let adapter: AudioSessionAdapter
  private(set) var events: [AudioSessionEvent] = []

  init(
    configuration: AudioSessionConfiguration = AudioSessionConfiguration(),
    ports: SessionPorts = SessionPorts(inputs: [.builtInMic], outputs: [.receiver])
  ) {
    adapter = AudioSessionAdapter(
      configuration: configuration, session: session, notifications: notifications)
    session.current = ports
    adapter.attach { [weak self] event in self?.events.append(event) }
  }
}

let voiceCall = Call(
  id: CallID(rawValue: "voice"), isIncoming: true, parties: [], status: .connecting)
let videoCall = Call(
  id: CallID(rawValue: "video"), isIncoming: true, parties: [], status: .connecting,
  hasVideo: true)

extension Port {
  static let builtInMic = Port(
    uid: "Built-In Microphone", name: "iPhone Microphone", type: .builtInMic)
  static let receiver = Port(uid: "Built-In Receiver", name: "Receiver", type: .builtInReceiver)
  static let speaker = Port(uid: "Speaker", name: "Speaker", type: .builtInSpeaker)
  static let airPodsHFP = Port(uid: "AA:BB-tsco", name: "AirPods Pro", type: .bluetoothHFP)
  static let headsetMic = Port(
    uid: "Wired Microphone", name: "Headset Microphone", type: .headsetMic)
  static let headphones = Port(uid: "Wired Headphones", name: "Headphones", type: .headphones)
  static let airPlay = Port(uid: "AirPlay-1", name: "Living Room", type: .airPlay)
  static let carInput = Port(uid: "CarPlay-In", name: "CarPlay", type: .carAudio)
  static let carOutput = Port(uid: "CarPlay-Out", name: "CarPlay", type: .carAudio)
  static let speakerA2DP = Port(uid: "CC:DD-a2dp", name: "Kitchen Speaker", type: .bluetoothA2DP)
}
