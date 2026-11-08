#if VOIP_CONVERSATIONS_LIVE_ACTIVITY
  import Foundation

  /// Call previews' Live Activities, with the `callPreviewActivities` plugin option: the SDK's
  /// `CallPreviewActivities` starts one for each call preview while the app is in the foreground,
  /// follows those that the app's servers start, and joins a call from its Join button.
  ///
  /// JavaScript reads what the servers need, the authorization, the push-to-start token and each
  /// preview's push token, as a revisioned snapshot, and follows each preview with `callPreview`
  /// conversation events.
  @MainActor
  final class CallPreviews {
    /// The observer that the client attaches as it starts. The Join intent joins calls through
    /// it.
    let activities = CallPreviewActivities()

    private let changed: @MainActor (JSONValue) -> Void
    private let emit: @MainActor (String, JSONValue) -> Void
    private var revision = 0
    private var pushToStartToken: Data?
    /// The push token of each preview that has one, in the order the previews started.
    private var pushTokens: [(callID: CallID, token: Data)] = []
    private var tasks: [Task<Void, Never>] = []

    /// Creates the call previews.
    ///
    /// - Parameters:
    ///   - changed: Sends a new snapshot to JavaScript.
    ///   - emit: Sends a conversation event's type and payload to JavaScript.
    init(
      changed: @escaping @MainActor (JSONValue) -> Void,
      emit: @escaping @MainActor (String, JSONValue) -> Void
    ) {
      self.changed = changed
      self.emit = emit
    }

    /// The TypeScript API's `CallPreviewActivitiesSnapshot`.
    var snapshot: JSONValue {
      .object([
        "revision": .number(Double(revision)),
        "activities": .object([
          "authorization": .object([
            "activitiesEnabled": .bool(activities.authorization.areActivitiesEnabled),
            "frequentPushesEnabled": .bool(activities.authorization.frequentPushesEnabled),
          ]),
          "pushToStartToken": pushToStartToken.map { .string($0.hex) } ?? .null,
          "pushTokens": .array(
            pushTokens.map { preview in
              .object([
                "conversationId": .string(preview.callID.rawValue),
                "token": .string(preview.token.hex),
              ])
            }),
        ]),
      ])
    }

    /// Follows the previews, their tokens and the authorization. The service calls it once,
    /// before it starts the client, so that the events of a cold launch reach JavaScript's
    /// snapshot.
    func start() {
      guard tasks.isEmpty else { return }
      let events = activities.events()
      let pushToStartTokens = activities.pushToStartTokens()
      let pushTokens = activities.pushTokens()
      let authorizations = activities.authorizationUpdates()
      tasks = [
        Task { [weak self] in
          for await event in events { self?.emit("callPreview", event.json) }
        },
        Task { [weak self] in
          for await token in pushToStartTokens {
            self?.pushToStartToken = token
            self?.publish()
          }
        },
        Task { [weak self] in
          for await token in pushTokens { self?.pushTokenChanged(token) }
        },
        Task { [weak self] in
          for await _ in authorizations { self?.publish() }
        },
      ]
    }

    private func pushTokenChanged(_ update: CallPreviewPushToken) {
      if let token = update.token {
        if let index = pushTokens.firstIndex(where: { $0.callID == update.callID }) {
          pushTokens[index].token = token
        } else {
          pushTokens.append((update.callID, token))
        }
      } else {
        pushTokens.removeAll { $0.callID == update.callID }
      }
      publish()
    }

    private func publish() {
      revision += 1
      changed(snapshot)
    }
  }

  extension CallPreviewActivities.Event {
    /// The TypeScript API's `CallPreviewEvent`.
    fileprivate var json: JSONValue {
      switch self {
      case .started(let id):
        .object(["type": .string("started"), "conversationId": .string(id.rawValue)])
      case .startFailed(let id, let error):
        .object([
          "type": .string("startFailed"), "conversationId": .string(id.rawValue),
          "error": error.startJSON,
        ])
      case .ended(let id):
        .object(["type": .string("ended"), "conversationId": .string(id.rawValue)])
      }
    }
  }

  extension CallPreviewError {
    /// The TypeScript API's `CallPreviewStartError`. Starting fails only with the first four
    /// cases.
    fileprivate var startJSON: JSONValue {
      switch self {
      case .activitiesDisabled: .string("activitiesDisabled")
      case .notInForeground: .string("notInForeground")
      case .tooLarge: .string("tooLarge")
      case .refused, .notStarted, .unknownCall, .notAttached, .join: .string("refused")
      }
    }
  }
#endif
