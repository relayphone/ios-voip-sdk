import Observation
import Testing
import VoIPCore

@testable import VoIPAudio

@Suite("Routes", .timeLimit(.minutes(1)))
struct RouteTests {
  /// The session's ports, and the routes that calls can use with them.
  struct Case: Sendable, CustomTestStringConvertible {
    let name: String
    let ports: SessionPorts
    var defaultsToSpeaker = false
    /// The routes, by identifier and kind.
    let routes: [Listed]
    let current: String

    var testDescription: String { name }
  }

  struct Listed: Hashable, Sendable, CustomTestStringConvertible {
    let id: String
    let kind: AudioRoute.Kind

    init(_ id: String, _ kind: AudioRoute.Kind) {
      self.id = id
      self.kind = kind
    }

    init(_ route: AudioRoute) {
      self.init(route.id.rawValue, route.kind)
    }

    var testDescription: String { "\(id) (\(kind))" }
  }

  static let receiver = Listed("input:Built-In Microphone", .builtInReceiver)
  static let speaker = Listed("speaker", .builtInSpeaker)

  static let cases: [Case] = [
    Case(
      name: "the receiver", ports: SessionPorts(inputs: [.builtInMic], outputs: [.receiver]),
      routes: [receiver, speaker], current: receiver.id),
    Case(
      name: "the speaker", ports: SessionPorts(inputs: [.builtInMic], outputs: [.speaker]),
      routes: [receiver, speaker], current: speaker.id),
    Case(
      name: "a Bluetooth hands-free device",
      ports: SessionPorts(inputs: [.builtInMic, .airPodsHFP], outputs: [.airPodsHFP]),
      routes: [receiver, speaker, Listed("input:AA:BB-tsco", .bluetooth)],
      current: "input:AA:BB-tsco"),
    Case(
      name: "a wired headset, which replaces the receiver",
      ports: SessionPorts(inputs: [.builtInMic, .headsetMic], outputs: [.headphones]),
      routes: [speaker, Listed("input:Wired Microphone", .headphones)],
      current: "input:Wired Microphone"),
    Case(
      name: "wired headphones without a microphone",
      ports: SessionPorts(inputs: [.builtInMic], outputs: [.headphones]),
      routes: [speaker, Listed("output:Wired Headphones", .headphones)],
      current: "output:Wired Headphones"),
    Case(
      name: "AirPlay, while it's the current route",
      ports: SessionPorts(inputs: [.builtInMic], outputs: [.airPlay]),
      routes: [receiver, speaker, Listed("output:AirPlay-1", .airPlay)],
      current: "output:AirPlay-1"),
    Case(
      name: "CarPlay, whose input and output differ",
      ports: SessionPorts(inputs: [.builtInMic, .carInput], outputs: [.carOutput]),
      routes: [receiver, speaker, Listed("input:CarPlay-In", .carAudio)],
      current: "input:CarPlay-In"),
    Case(
      name: "an A2DP speaker beside a hands-free headset",
      ports: SessionPorts(inputs: [.builtInMic, .airPodsHFP], outputs: [.speakerA2DP]),
      routes: [
        receiver, speaker, Listed("input:AA:BB-tsco", .bluetooth),
        Listed("output:CC:DD-a2dp", .bluetooth),
      ],
      current: "output:CC:DD-a2dp"),
    Case(
      name: "a video call, which plays through the speaker instead of the receiver",
      ports: SessionPorts(inputs: [.builtInMic], outputs: [.speaker]), defaultsToSpeaker: true,
      routes: [speaker], current: speaker.id),
  ]

  @Test(arguments: cases)
  func listsTheRoutesAndTheCurrentOne(_ row: Case) {
    let list = RouteList(row.ports, defaultsToSpeaker: row.defaultsToSpeaker)
    #expect(list.routes.map(Listed.init) == row.routes)
    #expect(list.current?.id.rawValue == row.current)
    #expect(Set(list.routes.map(\.id)).count == list.routes.count, "Each route is listed once")
  }

  @Test func routesKeepTheSystemsNames() {
    let list = RouteList(
      SessionPorts(inputs: [.builtInMic, .airPodsHFP], outputs: [.airPodsHFP]),
      defaultsToSpeaker: false)
    #expect(list.routes.map(\.name) == ["iPhone Microphone", "Speaker", "AirPods Pro"])
  }

  // MARK: Selection

  /// Selecting a route, and what the adapter asked of the session.
  struct Selection: Sendable, CustomTestStringConvertible {
    let name: String
    let ports: SessionPorts
    let route: String
    let records: [FakeSession.Record]

    var testDescription: String { name }
  }

  static let selections: [Selection] = [
    Selection(
      name: "the speaker overrides the output",
      ports: SessionPorts(inputs: [.builtInMic], outputs: [.receiver]), route: speaker.id,
      records: [.overrideOutput(toSpeaker: true)]),
    Selection(
      name: "the receiver clears the override and prefers the built-in microphone",
      ports: SessionPorts(inputs: [.builtInMic], outputs: [.speaker]), route: receiver.id,
      records: [.overrideOutput(toSpeaker: false), .setPreferredInput("Built-In Microphone")]),
    Selection(
      name: "a Bluetooth device prefers its microphone",
      ports: SessionPorts(inputs: [.builtInMic, .airPodsHFP], outputs: [.receiver]),
      route: "input:AA:BB-tsco",
      records: [.overrideOutput(toSpeaker: false), .setPreferredInput("AA:BB-tsco")]),
    Selection(
      name: "the current AirPlay route changes nothing",
      ports: SessionPorts(inputs: [.builtInMic], outputs: [.airPlay]), route: "output:AirPlay-1",
      records: []),
  ]

  @Test(arguments: selections)
  @VoIPActor
  func selectingARouteAsksTheSession(_ row: Selection) throws {
    let attached = Attached(ports: row.ports)
    try attached.adapter.selectRoute(AudioRoute.ID(rawValue: row.route))
    #expect(attached.session.records == row.records)
  }

  @Test @VoIPActor func aRouteThatIsntAvailableCantBeSelected() {
    let attached = Attached()
    #expect(throws: AudioRouteError.unavailable) {
      try attached.adapter.selectRoute(AudioRoute.ID(rawValue: "input:AA:BB-tsco"))
    }
    #expect(attached.session.records.isEmpty)
  }

  @Test @VoIPActor func aRefusedSelectionThrowsAndRereadsTheRoute() {
    let attached = Attached()
    attached.session.refusesRouteChanges = true
    // The system moved the call to the speaker on its own.
    attached.session.current = SessionPorts(inputs: [.builtInMic], outputs: [.speaker])
    #expect(throws: AudioRouteError.refused) {
      try attached.adapter.selectRoute(RouteList.speakerID)
    }
    #expect(attached.adapter.list.current?.id == RouteList.speakerID)
  }

  @Test @VoIPActor func aVideoCallsConfigurationHidesTheReceiver() throws {
    let attached = Attached(ports: SessionPorts(inputs: [.builtInMic], outputs: [.speaker]))
    #expect(attached.adapter.list.routes.map(\.kind) == [.builtInReceiver, .builtInSpeaker])
    try attached.adapter.configure(for: videoCall)
    #expect(attached.adapter.list.routes.map(\.kind) == [.builtInSpeaker])
    try attached.adapter.configure(for: voiceCall)
    #expect(attached.adapter.list.routes.map(\.kind) == [.builtInReceiver, .builtInSpeaker])
  }

  // MARK: Observing

  @Test @MainActor func theAppObservesRouteChanges() async {
    let attached = await Attached()
    let routes = attached.adapter.routes
    await until(routes) { $0.current?.kind == .builtInReceiver }
    #expect(routes.available.map(\.kind) == [.builtInReceiver, .builtInSpeaker])

    // AirPods connect, and the system routes the call to them.
    await onVoIPActor {
      attached.session.current = SessionPorts(
        inputs: [.builtInMic, .airPodsHFP], outputs: [.airPodsHFP])
      attached.notifications.post(.routesChanged)
    }
    await until(routes) { $0.current?.name == "AirPods Pro" }
    #expect(routes.available.map(\.kind) == [.builtInReceiver, .builtInSpeaker, .bluetooth])

    // The user picks the speaker.
    try? await attached.adapter.selectRoute(RouteList.speakerID)
    await onVoIPActor {
      attached.session.current.outputs = [.speaker]
      attached.notifications.post(.routesChanged)
    }
    await until(routes) { $0.current?.kind == .builtInSpeaker }
  }

  @Test @MainActor func anOlderListNeverReplacesANewerOne() {
    let routes = AudioRoutes()
    let speaker = AudioRoute(id: RouteList.speakerID, kind: .builtInSpeaker, name: "Speaker")
    routes.apply(RouteSnapshot(revision: 2, routes: [speaker], current: speaker))
    routes.apply(RouteSnapshot(revision: 1, routes: [], current: nil))
    #expect(routes.available == [speaker])
    #expect(routes.current == speaker)
  }
}

/// Runs a closure on `VoIPActor` in one job.
@VoIPActor
func onVoIPActor<Result: Sendable>(_ body: @VoIPActor () -> Result) -> Result {
  body()
}

/// Waits until the routes satisfy a condition.
@MainActor
func until(_ routes: AudioRoutes, _ condition: @escaping @MainActor (AudioRoutes) -> Bool) async {
  let observations = Observations { @MainActor in condition(routes) }
  for await satisfied in observations where satisfied { return }
}
