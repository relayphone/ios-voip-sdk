import Foundation
import Intents
import Observation
import Synchronization
import os

/// Runs the SDK's `VoIPClient` for the app, from launch, and translates between it and the
/// TypeScript API.
///
/// The app delegate subscriber starts the client before JavaScript runs, so a VoIP push that
/// launches the app is reported and the user can answer before JavaScript loads. The SDK keeps
/// every call's state; this service shows it as conversations, maps commands and reports to the
/// SDK's requests and server events, and passes the SDK's events to JavaScript.
@MainActor
final class CallService {
  static let shared = CallService()

  /// The latest `ConversationsSnapshot`, which JavaScript reads synchronously from its own
  /// thread.
  nonisolated static let snapshot = Mutex(
    JSONValue.object(["revision": .number(0), "conversations": .array([])]))

  private static let log = Logger(subsystem: "VoIPConversations", category: "calls")

  private let settings = Settings.main
  private let intake = PushIntake.shared
  private var client: VoIPClient?
  private var startError: CommandError?
  private var send: (@MainActor (String, JSONValue) -> Void)?
  private var emitterOwner: ObjectIdentifier?
  private lazy var handlers = HandlerActions(
    send: { [unowned self] in emit($0, $1) },
    conversation: { [unowned self] id in
      client?.calls.first { $0.id == id }.map { conversation($0) }
    },
    complete: { [unowned self] id, kind, outcome in complete(id, kind, outcome) },
    expired: { [unowned self] in publish() })
  private let audio = AudioSessionAdapter()
  private var routeRevision = 0
  private var routeValues = JSONValue.null
  #if VOIP_CONVERSATIONS_NOTIFICATIONS
    private lazy var notifications = CallNotifications(
      emit: { [unowned self] in emitConversationEvent($0, $1) },
      deliver: { [unowned self] in deliver($0, $1) })
  #endif
  #if VOIP_CONVERSATIONS_FOCUS
    private lazy var focusFilter = settings.focusAppGroup.map { appGroup in
      FocusFilter(appGroup: appGroup) { [unowned self] in emit("focusFilterStateChanged", $0) }
    }
  #endif
  #if VOIP_CONVERSATIONS_LIVE_ACTIVITY
    private lazy var previews = CallPreviews(
      changed: { [unowned self] in emit("callPreviewActivitiesChanged", $0) },
      emit: { [unowned self] in emitConversationEvent($0, $1) })
  #endif

  // Conversations
  private var revision = 0
  private var conversations = JSONValue.array([])
  /// Calls that ended, shown once with their end reason before they leave the snapshot.
  private var endedCalls: [(call: Call, at: Date)] = []
  /// Ended calls that the client may not have dropped yet.
  private var tombstones: Set<CallID> = []
  /// The conversation that a snapshot last showed for each call, so that its end is shown too.
  private var shown: [CallID: JSONValue] = [:]
  /// The participants JavaScript gave for outgoing calls and member updates.
  private var participants: [CallID: [JSONValue]] = [:]
  /// Actions the app requested that the SDK hasn't performed yet, to tell the handler their
  /// origin.
  private var requested = ActionOrigins()
  /// Requests that wait for the SDK to carry them out.
  private var waiters: [ActionWaiter] = []

  // Push token
  private var tokenRevision = 0
  private var token: JSONValue = .null

  // Conversation events
  private var observesConversationEvents = false
  /// Conversation events that the user's actions caused before JavaScript listened, the latest
  /// of each type, which the first listener receives.
  private var waiting: [(type: String, payload: JSONValue)] = []

  private init() {}

  // MARK: Lifecycle

  /// Starts the client, once. The app delegate subscriber calls it at launch.
  func start() {
    guard client == nil, startError == nil else { return }
    #if VOIP_CONVERSATIONS_FOCUS
      focusFilter?.start()
    #endif
    #if VOIP_CONVERSATIONS_SIMULATOR && DEBUG && targetEnvironment(simulator)
      VoIPSimulator.activate()
    #endif
    let framework = LiveCommunicationKitAdapter()
    // The app's native media, when it registered one, joins each call's media before
    // JavaScript loads. Otherwise JavaScript connects it.
    let registered = NativeCallMedia.registration
    let media: any CallMedia
    let audio: (any AudioSession)?
    if let registered {
      audio = self.audio
      media = RegisteredMedia(registered.media) { [weak self] in self?.publish() }
    } else {
      #if VOIP_CONVERSATIONS_WEBRTC
        let rtc = RTCAudioSessionMedia()
        media = rtc
        audio = AudioSessionBridge(adapter: self.audio) { rtc.rememberConfiguration() }
      #else
        media = AppManagedMedia()
        audio = nil
        Task { @VoIPActor [adapter = self.audio] in adapter.attach { _ in } }
      #endif
    }
    let intake = intake
    let push = PushKitSource { intake.decode($0) }
    // The subscription starts before the client attaches the push source, so it receives the
    // events of the VoIP push that launched the app.
    var observers: [any CallObserver] = [EventSubscription { [weak self] in self?.handle($0) }]
    #if VOIP_CONVERSATIONS_NOTIFICATIONS
      notifications.start()
      observers.append(notifications.notifier)
    #endif
    #if VOIP_CONVERSATIONS_LIVE_ACTIVITY
      previews.start()
      observers.append(previews.activities)
    #endif
    observers += registered?.observers ?? []
    let client: VoIPClient
    do {
      client = try VoIPClient.start(
        framework: framework, media: media, push: push, audio: audio, observers: observers,
        configuration: settings.configuration)
    } catch {
      Self.log.error("Another VoIPClient runs in this process, so calls are unavailable")
      startError = CommandError(
        code: .duplicateSDKLinkage, message: "Another VoIPClient runs in this process")
      return
    }
    self.client = client
    handlers.acceptsUnhandled = settings.acceptsUnhandledActions
    Task { [weak self] in
      for await _ in Observations({ client.calls }) { self?.publish() }
    }
    Task { [weak self] in
      for await token in push.tokens() { self?.tokenChanged(token) }
    }
    Task { [weak self, audio = self.audio] in
      for await _ in Observations({ (audio.routes.available, audio.routes.current) }) {
        self?.publishRoutes()
      }
    }
  }

  /// Whether the module started calls, or failed to.
  var isStarted: Bool { client != nil || startError != nil }

  /// The module for a new JavaScript runtime starts sending events.
  func attach(owner: ObjectIdentifier, send: @escaping @MainActor (String, JSONValue) -> Void) {
    start()
    emitterOwner = owner
    self.send = send
    handlers.reset()
    observesConversationEvents = false
  }

  /// The module stops sending events, unless a newer one took over.
  func detach(owner: ObjectIdentifier) {
    guard emitterOwner == owner else { return }
    emitterOwner = nil
    send = nil
    handlers.reset()
    observesConversationEvents = false
  }

  // MARK: State

  func snapshotNow() -> JSONValue {
    publish()
    return Self.snapshot.withLock { $0 }
  }

  var audioRoutes: JSONValue {
    publishRoutes()
    return routeValues
  }

  private func publishRoutes() {
    let values = ConversationEncoding.routes(audio.routes.available, current: audio.routes.current)
    guard routeValues["routes"] != values["routes"] || routeValues["current"] != values["current"]
    else { return }
    routeRevision += 1
    guard case .object(var fields) = values else { return }
    fields["revision"] = .number(Double(routeRevision))
    routeValues = .object(fields)
    emit("audioRoutesChanged", routeValues)
  }

  var pushToken: JSONValue {
    .object(["revision": .number(Double(tokenRevision)), "token": token])
  }

  /// The TypeScript API's `FocusFilterStateSnapshot`, whose `state` is null without the
  /// `focusFilter` plugin option.
  var focusFilterState: JSONValue {
    #if VOIP_CONVERSATIONS_FOCUS
      if let focusFilter { return focusFilter.snapshot }
    #endif
    return .object(["revision": .number(0), "state": .null])
  }

  /// The TypeScript API's `CallPreviewActivitiesSnapshot`, whose `activities` are null without
  /// the `callPreviewActivities` plugin option.
  var callPreviewActivities: JSONValue {
    #if VOIP_CONVERSATIONS_LIVE_ACTIVITY
      start()
      return previews.snapshot
    #else
      return .object(["revision": .number(0), "activities": .null])
    #endif
  }

  // MARK: Commands

  func startConversation(_ options: JSONValue) async throws(CommandError) -> String {
    let call = try ConversationEncoding.outgoing(options)
    let id = call.id
    guard try running().calls.allSatisfy({ $0.id != id }) else { throw .invalidArguments }
    participants[id] = options["to"].map { [$0] }
    do {
      try await request(.start(call))
    } catch {
      participants[id] = nil
      throw error
    }
    return id.rawValue
  }

  /// Answers a ringing call, or joins a call from its call preview.
  func joinConversation(_ id: String) async throws(CommandError) {
    let callID = CallID(rawValue: id)
    if case .previewing = try call(callID).status {
      try await request(.join(callID))
    } else {
      try await request(.answer(callID))
    }
  }

  func endConversation(_ id: String) async throws(CommandError) {
    try await request(.end(CallID(rawValue: id)))
  }

  func setHeld(_ id: String, _ held: Bool) async throws(CommandError) {
    let callID = CallID(rawValue: id)
    guard try call(callID).isOnHold != held else { return }
    try await request(.hold(callID, onHold: held))
  }

  func setMuted(_ id: String, _ muted: Bool) async throws(CommandError) {
    let callID = CallID(rawValue: id)
    guard try call(callID).isMuted != muted else { return }
    try await request(.mute(callID, muted: muted))
  }

  func playTones(_ id: String, _ digits: String) async throws(CommandError) {
    guard !digits.isEmpty, digits.allSatisfy({ "0123456789*#ABCDabcd".contains($0) }) else {
      throw .invalidArguments
    }
    try await request(.playTones(CallID(rawValue: id), digits: digits))
  }

  func mergeConversations(_ first: String, _ second: String) async throws(CommandError) {
    try await request(.merge(CallID(rawValue: first), with: CallID(rawValue: second)))
  }

  func selectAudioRoute(_ id: String) async throws(CommandError) {
    do { try await audio.selectRoute(AudioRoute.ID(rawValue: id)) } catch {
      throw CommandError(code: .conversation, message: "The audio route is unavailable or refused")
    }
  }

  // MARK: Reports

  /// Applies a transport fact about a call that JavaScript knows.
  ///
  /// A `connecting` or `connected` report for a call that isn't placed yet, which only the app's
  /// start or join handler can send, is held by the SDK and applied once the call is placed. It
  /// returns without waiting for that, because the placement waits for the handler.
  func reportConversation(_ id: String, _ report: JSONValue) async throws(CommandError) {
    let callID = CallID(rawValue: id)
    _ = try call(callID)
    switch report["type"]?.string {
    case "connecting":
      await receive(.connecting, for: callID)
    case "connected":
      await receive(.connected, for: callID)
    case "updated":
      // The SDK keeps whether a call has video from its start; only members change.
      guard let members = report["members"]?.array else { return }
      guard !members.isEmpty else { throw .invalidArguments }
      var parties: [Party] = []
      for member in members { parties.append(try Party(participant: member)) }
      participants[callID] = members
      await receive(.partiesChanged(parties), for: callID)
    case "ended":
      switch report["reason"]?.string {
      case "local": try await request(.end(callID))
      case "remoteEnded": await receive(.endedRemotely, for: callID)
      case "failed": await receive(.failed, for: callID)
      case "unanswered": await receive(.unanswered, for: callID)
      case "answeredElsewhere": await receive(.answeredElsewhere, for: callID)
      case "declinedElsewhere": await receive(.declinedElsewhere, for: callID)
      default: throw .invalidArguments
      }
    default:
      throw .invalidArguments
    }
  }

  /// Presents an incoming call that JavaScript learned about, and returns how it appears.
  func reportIncomingConversation(_ payload: JSONValue) async throws(CommandError) -> JSONValue {
    let client = try running()
    guard
      let data = try? JSONValue.object(["incomingCall": payload]).data(),
      case .incoming(let incoming, _) = VoIPPush(defaultFormat: data)
    else {
      return .object(["status": .string("failed"), "error": CommandError.invalidArguments.json])
    }
    intake.record(payload, for: incoming.id, viaPush: false)
    let outcome = await client.report(incoming).json(id: incoming.id)
    publish()
    emitIncomingOutcome(payload: payload, outcome: outcome)
    return outcome
  }

  /// Applies a server's end signal for an incoming call, and returns whether this device knows
  /// the call. A signal for a call that hasn't arrived yet is kept until it does.
  func receiveCallEnded(_ payload: JSONValue) async throws(CommandError) -> Bool {
    let client = try running()
    guard
      let body = try? payload.data(), let text = String(data: body, encoding: .utf8),
      let data = try? JSONValue.object([
        "messageType": .string("callEnded"), "callEnded": .string(text),
      ]).data(),
      case .serverEvent(let event, let id, let eventID) = VoIPPush(defaultFormat: data)
    else { return false }
    if event == .answeredElsewhere { intake.recordAnsweredElsewhere(eventID, for: id) }
    let isKnown = client.calls.contains { $0.id == id }
    await client.receive(event, for: id, eventID: eventID)
    publish()
    return isKnown
  }

  // MARK: Handler and listeners

  func setHandlerAttached(_ attached: Bool, generation: Int) {
    handlers.attach(attached, generation: generation)
    publish()
  }

  func settleAction(_ actionID: String, generation: Int, success: Bool) {
    handlers.settle(actionID, generation: generation, success: success)
    publish()
  }

  /// JavaScript started or stopped listening for conversation events. The first listener
  /// receives the events that waited for one.
  func observeConversationEvents(_ observes: Bool) {
    observesConversationEvents = observes
    guard observes, send != nil else { return }
    let waiting = self.waiting
    self.waiting = []
    for event in waiting { emitConversationEvent(event.type, event.payload) }
  }

  /// The user asked to call someone from Recents, Siri or Contacts.
  ///
  /// With call notifications, a request for a party whose call is live in a call preview joins
  /// that call. Otherwise JavaScript receives a `dialRequest` conversation event.
  ///
  /// - Returns: Whether the activity holds such a request.
  func continueCall(_ activity: NSUserActivity) -> Bool {
    guard
      let intent = activity.interaction?.intent as? INStartCallIntent,
      let handle = intent.contacts?.first?.personHandle?.value
    else { return false }
    let video = intent.callCapability == .videoCall
    #if VOIP_CONVERSATIONS_NOTIFICATIONS
      if let request = StartCallRequest(intent) {
        Task {
          guard let callBack = await notifications.route(request) else { return }
          dialRequested(handle: callBack.party.presentedHandle.value, video: callBack.hasVideo)
        }
        return true
      }
    #endif
    dialRequested(handle: handle, video: video)
    return true
  }

  /// Without a listener, the latest dial request waits for one.
  private func dialRequested(handle: String, video: Bool) {
    deliver("dialRequest", .object(["handle": .string(handle), "video": .bool(video)]))
  }

  // MARK: SDK events

  private func handle(_ event: CallEvent) {
    defer {
      for waiter in waiters where waiter.isCarriedOut(by: event) { waiter.finish() }
    }
    switch event {
    case .presented(let call):
      emitPushOutcome(for: call.id, PresentationOutcome.presented.json(id: call.id))
    case .joinFailed(let call, let failure):
      handlers.cancel(call.id, reason: "joinFailed")
      requested.cancelPlacement(for: call.id)
      for waiter in waiters where waiter.places(call.id) && waiter.failure == nil {
        waiter.failure = CommandError(
          code: .conversation, message: "The conversation could not be joined")
      }
      emitConversationEvent("joinFailed", ConversationEncoding.joinFailed(call, failure))
    case .previewStarted(let call):
      // A join that failed returns to the preview.
      handlers.cancel(call.id, reason: "cancelled")
      guard case .previewing(let reason) = call.status else { break }
      publish()
      emitPushOutcome(for: call.id, PresentationOutcome.previewed(reason).json(id: call.id))
      if reason == .answeredElsewhere { emitAnsweredElsewhere(call.id) }
    case .startRequested(let call):
      let origin = requested.placement(for: call.id)
      // JavaScript is running, so no handler will place the call: it fails now instead of at
      // the placement deadline.
      if origin == .app, !handlers.isAttached, !handlers.acceptsUnhandled {
        notPlaced(call.id, CommandError(code: .deadlineExceeded, message: "No handler is set"))
      } else {
        gate(.start, call, origin: origin)
      }
    case .joinRequested(let call):
      gate(.join, call, origin: requested.placement(for: call.id))
    case .performed(let action, let call):
      let origin = requested.take(action)
      publish()
      emitConversationEvent(
        "actionPerformed", ConversationEncoding.performed(action, call, origin: origin))
    case .audioActivated:
      publishRoutes()
      emit(
        "conversationEvent", .object(["type": .string("audioActivated"), "payload": .object([:])]))
    case .audioDeactivated, .audioInterrupted, .mediaServicesReset:
      // Native media uses the SDK's audio session adapter, which also reports interruptions
      // and resets. The JavaScript path forwards only the calling framework's deactivation;
      // WebRTC owns its session configuration. All three events stop audio for JavaScript.
      publishRoutes()
      emit(
        "conversationEvent",
        .object(["type": .string("audioDeactivated"), "payload": .object([:])]))
    case .ended(let call):
      ended(call)
    }
    publish()
  }

  private func ended(_ call: Call) {
    handlers.cancel(call.id, reason: "cancelled")
    requested.ended(call.id)
    guard case .ended(let reason) = call.status else { return }
    switch reason {
    case .filtered(let cause):
      emitPushOutcome(for: call.id, PresentationOutcome.filtered(cause).json(id: call.id))
    case .failed(let failure):
      emitPushOutcome(for: call.id, PresentationOutcome.refused(failure).json(id: call.id))
    default:
      break
    }
    tombstones.insert(call.id)
    if shown.removeValue(forKey: call.id) != nil {
      endedCalls.append((call, Date.now))
      publish()
      endedCalls.removeAll { $0.call.id == call.id }
    }
    let conversation = JSONValue.object(["conversationId": .string(call.id.rawValue)])
    switch reason {
    case .answeredElsewhere:
      emitAnsweredElsewhere(call.id)
    case .failed(.audioActivationTimedOut):
      emit(
        "conversationEvent",
        .object(["type": .string("audioActivationMissing"), "payload": conversation]))
    case .failed(.frameworkReset):
      emit(
        "conversationEvent", .object(["type": .string("providerReset"), "payload": .object([:])]))
    default:
      break
    }
    participants[call.id] = nil
    intake.forget(call.id)
    RegisteredMedia.prepared.withLock { _ = $0.remove(call.id) }
  }

  // MARK: Snapshots

  /// Sends a new snapshot when the conversations changed.
  private func publish() {
    guard let client else { return }
    let live = client.calls
    tombstones.formIntersection(live.map(\.id))
    var list: [JSONValue] = []
    var listed: Set<CallID> = []
    for call in live where !tombstones.contains(call.id) {
      let shownCall = conversation(call)
      list.append(shownCall)
      listed.insert(call.id)
      shown[call.id] = shownCall
    }
    // The client drops an ended call from its calls before its `ended` event arrives. Until the
    // event shows how the call ended, it stays as it was last shown, instead of leaving and
    // coming back as ended.
    for id in shown.keys.sorted(by: { $0.rawValue < $1.rawValue }) where !listed.contains(id) {
      if let shownCall = shown[id] { list.append(shownCall) }
    }
    for ended in endedCalls { list.append(conversation(ended.call, endedAt: ended.at)) }
    let conversations = JSONValue.array(list)
    guard conversations != self.conversations else { return }
    self.conversations = conversations
    revision += 1
    let snapshot = JSONValue.object([
      "revision": .number(Double(revision)), "conversations": conversations,
    ])
    Self.snapshot.withLock { $0 = snapshot }
    emit("conversationsChanged", snapshot)
  }

  /// The call as the TypeScript API's `Conversation`.
  private func conversation(_ call: Call, endedAt: Date = .now) -> JSONValue {
    let payload = intake.payload(for: call.id)
    return ConversationEncoding.conversation(
      call, members: members(of: call, payload: payload), capabilities: settings.capabilities,
      payload: payload, pending: handlers.pending(for: call.id),
      nativeMedia: RegisteredMedia.prepared.withLock { $0.contains(call.id) }, endedAt: endedAt)
  }

  /// The participants JavaScript gave, or else the call's parties. An incoming caller's host
  /// contact ID identifies it.
  private func members(of call: Call, payload: JSONValue?) -> [JSONValue] {
    if let members = participants[call.id] { return members }
    var members = call.parties.map(\.participant)
    if let contact = payload?["caller"]?["hostContactID"],
      case .object(var first)? = members.first
    {
      first["id"] = contact
      members[0] = .object(first)
    }
    return members
  }

  // MARK: Helpers

  private func running() throws(CommandError) -> VoIPClient {
    start()
    guard let client else {
      throw startError ?? CommandError(code: .conversation, message: "Calls are unavailable")
    }
    return client
  }

  private func call(_ id: CallID) throws(CommandError) -> Call {
    guard let call = try running().calls.first(where: { $0.id == id }) else {
      throw .unknownConversation
    }
    return call
  }

  /// Requests an action, and returns once the SDK carried it out, so that the conversations
  /// show it: once the SDK performed it, or once the call ended or became a call preview.
  ///
  /// The SDK performs a start or join after the app's handler placed the call, so a `connecting` or `connected` report sent after the command
  /// applies at once instead of being held. The handler runs while the command waits, so it must
  /// not wait for the command.
  private func request(_ action: Action) async throws(CommandError) {
    let client = try running()
    requested.append(action)
    // The SDK's event can arrive before the request returns.
    let waiter = ActionWaiter(action)
    waiters.append(waiter)
    do {
      try await client.request(action)
    } catch {
      requested.withdraw(action)
      waiters.removeAll { $0 === waiter }
      publish()
      // The calling framework may refuse a start that the module already failed.
      throw waiter.failure ?? CommandError(error)
    }
    await waiter.wait()
    waiters.removeAll { $0 === waiter }
    publish()
    if let failure = waiter.failure { throw failure }
  }

  private func receive(_ event: ServerEvent, for id: CallID) async {
    guard let client else { return }
    await client.receive(event, for: id, eventID: EventID(rawValue: UUID().uuidString))
    publish()
  }

  /// Waits for the handler to place a call that the SDK asked the app to start or join.
  private func gate(_ kind: HandlerActions.Kind, _ call: Call, origin: HandlerActions.Origin) {
    handlers.gate(
      kind, call: call.id, conversation: conversation(call), origin: origin,
      placement: settings.configuration.deadlines.placement)
  }

  /// Places a call that the handler started or joined. When the handler didn't place it, a start
  /// fails and a join returns to its call preview.
  private func complete(
    _ id: CallID, _ kind: HandlerActions.Kind, _ outcome: HandlerActions.Outcome
  ) {
    guard let client else { return }
    switch outcome {
    case .placed:
      Task {
        await client.confirmPlaced(id)
        publish()
      }
    case .failed:
      notPlaced(
        id, CommandError(code: .handlerFailed, message: "The \(kind.rawValue) handler failed"))
    case .expired:
      notPlaced(
        id,
        CommandError(code: .deadlineExceeded, message: "The \(kind.rawValue) handler timed out"))
    }
  }

  /// Tells the SDK that the app didn't place a call it was asked to start or join. An outgoing call ends as `failed` with the `notPlaced` failure, and a call being
  /// joined returns to its call preview. Either way, the app's `startConversation` or
  /// `joinConversation` for the call rejects with the given failure.
  private func notPlaced(_ id: CallID, _ failure: CommandError) {
    guard let client else { return }
    for waiter in waiters where waiter.places(id) { waiter.failure = failure }
    Task {
      await client.confirmNotPlaced(id)
      publish()
    }
  }

  private func tokenChanged(_ data: Data?) {
    let value = data?.hex
    let token: JSONValue =
      value.map { .object(["type": .string("apns-voip"), "value": .string($0)]) } ?? .null
    guard token != self.token else { return }
    self.token = token
    tokenRevision += 1
    emit("pushTokenUpdated", pushToken)
  }

  private func emitIncomingOutcome(payload: JSONValue, outcome: JSONValue) {
    emit(
      "conversationEvent",
      .object([
        "type": .string("incomingConversationOutcome"),
        "payload": .object([
          "eventId": payload["eventId"] ?? .null, "serverCallId": payload["serverCallId"] ?? .null,
          "outcome": outcome,
        ]),
      ]))
  }

  /// Tells JavaScript how a call that a VoIP push brought appeared, once.
  private func emitPushOutcome(for id: CallID, _ outcome: JSONValue) {
    guard let payload = intake.takePushOutcome(for: id) else { return }
    emitIncomingOutcome(payload: payload, outcome: outcome)
  }

  private func emitAnsweredElsewhere(_ id: CallID) {
    guard let eventID = intake.answeredElsewhereEvent(for: id) else { return }
    emit(
      "conversationEvent",
      .object([
        "type": .string("answeredElsewhere"),
        "payload": .object([
          "conversationId": .string(id.rawValue), "serverCallId": .string(id.rawValue),
          "eventId": .string(eventID.rawValue),
        ]),
      ]))
  }

  /// Sends a conversation event that the app must not miss, because the user's action caused
  /// it. Without a listener, the latest event of its type waits for one.
  private func deliver(_ type: String, _ payload: JSONValue) {
    guard observesConversationEvents, send != nil else {
      waiting.removeAll { $0.type == type }
      waiting.append((type, payload))
      return
    }
    emitConversationEvent(type, payload)
  }

  private func emitConversationEvent(_ type: String, _ payload: JSONValue) {
    emit("conversationEvent", .object(["type": .string(type), "payload": payload]))
  }

  private func emit(_ name: String, _ body: JSONValue) {
    send?(name, body)
  }
}

/// Follows the client's events from the moment it starts.
///
/// The client attaches its observers before the calling framework, the audio session and the push
/// source, so a stream created in ``attach(to:)`` receives every event, including those of the VoIP
/// push that launched the app. A stream created after `VoIPClient.start` returns can miss them.
@MainActor
private final class EventSubscription: CallObserver {
  private let handle: @MainActor (CallEvent) -> Void
  private var task: Task<Void, Never>?

  init(_ handle: @escaping @MainActor (CallEvent) -> Void) {
    self.handle = handle
  }

  func attach(to client: VoIPClient) {
    // Subscribes here, before any push can arrive, and reads the stream in a task.
    let events = client.events()
    task = Task { [handle] in
      for await event in events { handle(event) }
    }
  }
}

/// A request that waits for the SDK's event that carries it out.
@MainActor
private final class ActionWaiter {
  /// How long a request waits at most. The SDK's own deadlines end a call that stalls.
  private static let limit = Duration.seconds(10)

  let action: Action
  /// Why the command fails although the SDK carried out its request.
  var failure: CommandError?
  private var isFinished = false
  private var continuation: CheckedContinuation<Void, Never>?

  init(_ action: Action) {
    self.action = action
  }

  /// Whether the request starts or joins the call, and so waits for the app to place it.
  func places(_ id: CallID) -> Bool {
    switch action {
    case .start(let outgoing): outgoing.id == id
    case .join(let joined): joined == id
    default: false
    }
  }

  /// Whether the event carries out the request. The SDK performs a start once the app placed the
  /// call and its media is prepared; the start it performs is matched by its call.
  func isCarriedOut(by event: CallEvent) -> Bool {
    switch event {
    case .performed(.start(let started), _):
      if case .start(let outgoing) = action { outgoing.id == started.id } else { false }
    case .performed(let performed, _): performed == action
    case .ended(let call), .previewStarted(let call), .joinFailed(let call, _):
      call.id == action.callID
    case .presented, .startRequested, .joinRequested, .audioActivated, .audioDeactivated,
      .audioInterrupted, .mediaServicesReset:
      false
    }
  }

  func finish() {
    isFinished = true
    continuation?.resume()
    continuation = nil
  }

  func wait() async {
    guard !isFinished else { return }
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      Task { [weak self] in
        try? await Task.sleep(for: Self.limit)
        self?.finish()
      }
    }
  }
}
