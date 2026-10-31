/// The routes that calls can use, projected from the audio session's ports, with how to select
/// each.
///
/// Each available input is a route: selecting it prefers that microphone, and the system routes
/// output to match, as it does for the built-in microphone and the receiver, a headset, or a
/// Bluetooth hands-free device. The built-in speaker is always a route. An output that no listed
/// route stands for, such as AirPlay or a Bluetooth A2DP speaker, is a route while it's current,
/// since only the system's route picker selects it.
struct RouteList: Hashable, Sendable {
  /// How the adapter selects a route.
  enum Selection: Hashable, Sendable {
    /// Override the output to the built-in speaker.
    case speaker
    /// Clear the speaker override and prefer the input.
    case input(uid: String)
    /// Nothing: the route is the current output, which only the system selects.
    case current
  }

  static let speakerID = AudioRoute.ID(rawValue: "speaker")

  /// The routes, built-in ones first, then other inputs in the system's order, then the current
  /// output when no other route stands for it.
  private(set) var routes: [AudioRoute] = []
  /// The route that calls' audio uses now.
  private(set) var currentID: AudioRoute.ID?
  private var selections: [AudioRoute.ID: Selection] = [:]

  /// No routes, before the adapter first reads the session.
  init() {}

  /// Projects the routes from the session's ports.
  ///
  /// - Parameters:
  ///   - ports: The session's available inputs and current outputs.
  ///   - defaultsToSpeaker: Whether the session plays through the speaker, rather than the
  ///     receiver, when nothing else is connected.
  init(_ ports: SessionPorts, defaultsToSpeaker: Bool) {
    let output = ports.outputs.first
    // Wired headphones, or the speaker default, take the receiver's place.
    let hasReceiver = !defaultsToSpeaker && output?.type != .headphones
    var builtIn: [AudioRoute] = []
    var others: [AudioRoute] = []
    var seen: Set<String> = []
    for input in ports.inputs where seen.insert(input.uid).inserted {
      let kind = AudioRoute.Kind(input.type)
      if kind == .builtInReceiver, !hasReceiver { continue }
      let route = AudioRoute(
        id: AudioRoute.ID(rawValue: "input:\(input.uid)"), kind: kind, name: input.name)
      selections[route.id] = .input(uid: input.uid)
      if kind == .builtInReceiver { builtIn.append(route) } else { others.append(route) }
    }
    builtIn.append(AudioRoute(id: Self.speakerID, kind: .builtInSpeaker, name: "Speaker"))
    selections[Self.speakerID] = .speaker
    routes = builtIn + others

    guard let output else { return }
    if let current = Self.route(for: output, in: routes) {
      currentID = current.id
    } else {
      let route = AudioRoute(
        id: AudioRoute.ID(rawValue: "output:\(output.uid)"), kind: AudioRoute.Kind(output.type),
        name: output.name)
      routes.append(route)
      selections[route.id] = .current
      currentID = route.id
    }
  }

  /// The route that calls' audio uses now.
  var current: AudioRoute? {
    routes.first { $0.id == currentID }
  }

  /// How to select a route, or `nil` when it isn't available.
  func selection(for id: AudioRoute.ID) -> Selection? {
    selections[id]
  }

  /// The listed route that stands for an output: the speaker, the receiver, the input on the same
  /// device, or for a wired, CarPlay or USB output, whose input can have another identifier, the
  /// only input of its kind.
  private static func route(for output: Port, in routes: [AudioRoute]) -> AudioRoute? {
    let kind = AudioRoute.Kind(output.type)
    switch kind {
    case .builtInSpeaker, .builtInReceiver:
      return routes.first { $0.kind == kind }
    default:
      if let device = routes.first(where: { $0.id.rawValue == "input:\(output.uid)" }) {
        return device
      }
      guard [.headphones, .carAudio, .usbAudio].contains(kind) else { return nil }
      let sameKind = routes.filter { $0.kind == kind }
      return sameKind.count == 1 ? sameKind.first : nil
    }
  }
}

extension AudioRoute.Kind {
  /// The kind of route that a port belongs to.
  init(_ type: Port.PortType) {
    self =
      switch type {
      case .builtInMic, .builtInReceiver: .builtInReceiver
      case .builtInSpeaker: .builtInSpeaker
      case .headphones, .headsetMic: .headphones
      case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: .bluetooth
      case .airPlay: .airPlay
      case .carAudio: .carAudio
      case .usbAudio: .usbAudio
      case .other: .other
      }
  }
}
