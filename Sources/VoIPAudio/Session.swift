#if SWIFT_PACKAGE
  import VoIPCore
#endif

/// The parts of `AVAudioSession` that the adapter uses. The system's session is behind it on iOS,
/// and tests use a fake.
@VoIPActor
protocol SessionControl: Sendable {
  /// Sets the play-and-record category in voice chat mode with the options, without activating
  /// the session.
  func setCategory(options: CategoryOptions) throws(AudioSessionError)

  /// The session's available inputs and its current route's outputs.
  func ports() -> SessionPorts

  /// Routes output to the built-in speaker, or back to the route the system chooses.
  func overrideOutput(toSpeaker: Bool) throws(AudioRouteError)

  /// Prefers an available input. The system routes output to match it.
  func setPreferredInput(uid: String) throws(AudioRouteError)
}

/// The audio session's notifications. `NotificationCenter` is behind it on iOS, and tests use a
/// fake.
@VoIPActor
protocol SessionNotifications: Sendable {
  /// Starts delivering the audio session's notifications to `receive` on `VoIPActor`, in the
  /// order the system posts them.
  func start(_ receive: @escaping @VoIPActor (SessionNotification) -> Void)
}

/// An audio session notification, in the shape that the running system posts it.
enum SessionNotification: Hashable, Sendable {
  /// Before iOS 27, `AVAudioSession.interruptionNotification` with the began type, and its reason
  /// when it has one.
  case interruptionBegan(AudioInterruptionReason?)
  /// Before iOS 27, `AVAudioSession.interruptionNotification` with the ended type.
  case interruptionEnded
  /// From iOS 27, `AVAudioSession.didBecomeInactiveNotification`, with the interruption's reason
  /// when another session interrupted this one. Without one, the app or the system deactivated
  /// the session.
  case becameInactive(interruption: AudioInterruptionReason?)
  /// From iOS 27, `AVAudioSession.resumptionRecommendationNotification`, which follows an
  /// interruption.
  case resumptionRecommended
  /// `AVAudioSession.mediaServicesWereResetNotification`.
  case mediaServicesWereReset
  /// `AVAudioSession.routeChangeNotification` or `availableInputsChangeNotification`.
  case routesChanged
}

/// The audio session's ports that route projection reads.
struct SessionPorts: Hashable, Sendable {
  /// The inputs the session can use, in the system's order.
  var inputs: [Port]
  /// The current route's outputs.
  var outputs: [Port]
}

/// One of the audio session's ports, as `AVAudioSessionPortDescription` describes it.
struct Port: Hashable, Sendable {
  /// `AVAudioSession.Port`, for the port types that route projection tells apart.
  enum PortType: Hashable, Sendable {
    case builtInMic
    case builtInReceiver
    case builtInSpeaker
    case headphones
    case headsetMic
    case bluetoothHFP
    case bluetoothA2DP
    case bluetoothLE
    case airPlay
    case carAudio
    case usbAudio
    case other
  }

  /// The system's identifier for the port.
  var uid: String
  /// The system's name for the port.
  var name: String
  var type: PortType
}

/// `AVAudioSession.CategoryOptions`, for the options the adapter sets.
struct CategoryOptions: OptionSet, Hashable, Sendable {
  let rawValue: UInt8

  static let allowBluetoothHFP = CategoryOptions(rawValue: 1 << 0)
  static let allowBluetoothA2DP = CategoryOptions(rawValue: 1 << 1)
  static let allowAirPlay = CategoryOptions(rawValue: 1 << 2)
  static let defaultToSpeaker = CategoryOptions(rawValue: 1 << 3)
}
