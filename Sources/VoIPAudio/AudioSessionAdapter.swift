#if SWIFT_PACKAGE
  public import VoIPCore
#endif

/// The audio session for calls: it configures Apple's `AVAudioSession` for each call, tells the
/// SDK when the system interrupts the session or the media services reset, and lists the audio
/// routes that calls can use.
///
/// Create it when the app launches, pass it to
/// `VoIPClient.start(framework:media:push:audio:configuration:clock:)`, and show ``routes`` in
/// the app's audio route picker:
///
/// ```swift
/// let audio = AudioSessionAdapter()
/// let client = try VoIPClient.start(
///   framework: LiveCommunicationKitAdapter(), media: AppMedia(), push: PushKitSource(),
///   audio: audio)
/// ```
///
/// Before the SDK completes an answer, start or join, the adapter sets the play-and-record
/// category in voice chat mode with the options that ``AudioSessionConfiguration`` chooses for the
/// call. It never activates or deactivates the session: for calls only the system does, and the
/// calling framework tells the SDK.
///
/// From iOS 27 the system reports interruptions with `AVAudioSession.didBecomeInactiveNotification`
/// and `resumptionRecommendationNotification`; before, with `interruptionNotification`. The
/// adapter reads whichever the running system posts.
@VoIPActor
public final class AudioSessionAdapter: AudioSession {
  /// The audio routes that calls can use, on the main actor.
  public nonisolated let routes: AudioRoutes

  private let configuration: AudioSessionConfiguration
  private let session: any SessionControl
  private let notifications: any SessionNotifications
  private var onEvent: (@VoIPActor (AudioSessionEvent) -> Void)?
  /// The routes as the adapter last read them.
  private(set) var list = RouteList()
  private var revision: UInt64 = 0
  /// Whether the last configuration plays through the speaker when nothing else is connected.
  private var defaultsToSpeaker = false

  #if os(iOS)
    /// Creates the adapter for the app's audio session.
    ///
    /// - Parameter configuration: How the SDK configures the audio session for calls.
    public nonisolated convenience init(
      configuration: AudioSessionConfiguration = AudioSessionConfiguration()
    ) {
      self.init(
        configuration: configuration, session: SystemSession(),
        notifications: SystemNotifications())
    }
  #endif

  nonisolated init(
    configuration: AudioSessionConfiguration, session: any SessionControl,
    notifications: any SessionNotifications
  ) {
    self.configuration = configuration
    self.session = session
    self.notifications = notifications
    routes = AudioRoutes()
  }

  /// Routes calls' audio to an available route.
  ///
  /// Selecting the speaker overrides the output to the built-in speaker. Selecting another route
  /// prefers its microphone, and the system routes output to match: the receiver for the built-in
  /// microphone, or the headset, Bluetooth device or car. Selecting the current output-only
  /// route does nothing. The system may change the route again, for example when a device
  /// connects.
  ///
  /// - Parameter id: The route's identifier from ``routes``.
  /// - Throws: ``AudioRouteError/unavailable`` when the route isn't available, or
  ///   ``AudioRouteError/refused`` when the audio session refuses the change.
  public func selectRoute(_ id: AudioRoute.ID) throws(AudioRouteError) {
    defer { refreshRoutes() }
    switch list.selection(for: id) {
    case nil:
      throw .unavailable
    case .speaker?:
      try session.overrideOutput(toSpeaker: true)
    case .input(let uid)?:
      try session.overrideOutput(toSpeaker: false)
      try session.setPreferredInput(uid: uid)
    case .current?:
      break
    }
  }

  // MARK: AudioSession

  /// Starts watching the audio session's notifications and routes.
  public func attach(onEvent: @escaping @VoIPActor (AudioSessionEvent) -> Void) {
    guard self.onEvent == nil else { return }
    self.onEvent = onEvent
    notifications.start { [weak self] notification in
      self?.receive(notification)
    }
    refreshRoutes()
  }

  /// Sets the play-and-record category in voice chat mode, with the options the configuration
  /// chooses for the call.
  public func configure(for call: Call) throws(AudioSessionError) {
    let options = configuration.options(for: call)
    try session.setCategory(options: options)
    // The system reports the route change that the new category causes. Only the receiver's place
    // in the list depends on the configuration.
    let speakerByDefault = options.contains(.defaultToSpeaker)
    guard speakerByDefault != defaultsToSpeaker else { return }
    defaultsToSpeaker = speakerByDefault
    refreshRoutes()
  }

  // MARK: The system

  private func receive(_ notification: SessionNotification) {
    switch notification {
    case .interruptionBegan(let reason):
      onEvent?(.interruptionBegan(reason ?? .otherAudio))
    case .becameInactive(let interruption?):
      onEvent?(.interruptionBegan(interruption))
    case .becameInactive(nil):
      // The calling framework reports the system's own deactivations, and the adapter never
      // deactivates the session.
      break
    case .interruptionEnded, .resumptionRecommended:
      onEvent?(.interruptionEnded)
    case .mediaServicesWereReset:
      onEvent?(.mediaServicesReset)
      refreshRoutes()
    case .routesChanged:
      refreshRoutes()
    }
  }

  /// Reads the routes again, and publishes them when they changed.
  private func refreshRoutes() {
    let next = RouteList(session.ports(), defaultsToSpeaker: defaultsToSpeaker)
    guard next != list else { return }
    list = next
    revision += 1
    let snapshot = RouteSnapshot(revision: revision, routes: next.routes, current: next.current)
    Task { @MainActor [routes] in routes.apply(snapshot) }
  }
}
