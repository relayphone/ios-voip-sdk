#if DEBUG
  import Foundation

  /// The app owns publication; SDK observations only select its media policy.
  @MainActor protocol MediaVideoTransport: AnyObject {
    func start(epoch: UInt32, muted: Bool) async throws
    func mute() async throws
    func stop() async throws
  }

  /// A hold and its audio-session deactivation can arrive through separate callbacks.
  @MainActor final class MediaHoldMicrophoneGate {
    private var muteTask: Task<Void, any Error>?

    func mute(_ apply: @escaping @MainActor () async throws -> Void) async throws {
      if let muteTask {
        try await muteTask.value
      } else {
        let task = Task { try await apply() }
        muteTask = task
        try await task.value
      }
    }

    func restore(_ apply: () async throws -> Void) async throws {
      try await muteTask?.value
      try await apply()
      muteTask = nil
    }
  }

  /// Serialized with teardown, including when a Room release races an SDK callback.
  @MainActor final class MediaVideoPolicy {
    enum State: String, Encodable { case off, publishing, held, ended }
    enum Failure: Error { case exhausted, ended, expired }
    private(set) var state = State.off
    private(set) var epoch: UInt32 = 0
    private let transport: any MediaVideoTransport
    private var tail: Task<Void, any Error>?
    init(transport: any MediaVideoTransport) { self.transport = transport }

    func apply(hasVideo: Bool, held: Bool, ended: Bool = false) async throws {
      let previous = tail
      let turn = Task { @MainActor in
        // A failed operation poisons future positive transitions, but cleanup still runs.
        if ended {
          _ = try? await previous?.value
          self.state = .ended
          try await self.transport.stop()
          return
        }
        try await previous?.value
        guard self.state != .ended else { throw Failure.ended }
        if !hasVideo {
          if self.state != .off { try await self.transport.stop() }
          self.state = .off
        } else if held {
          if self.state == .off {
            try await self.start(muted: true)
          }
          if self.state == .publishing { try await self.transport.mute() }
          self.state = .held
        } else if self.state != .publishing {
          // The held source kept ticking behind the real publication gate. A new source/epoch
          // on resume makes queued frames from the old publication ineligible as fresh evidence.
          if self.state == .held { try await self.transport.stop() }
          try await self.start(muted: false)
        }
      }
      tail = turn
      try await turn.value
    }
    private func start(muted: Bool) async throws {
      guard epoch < 64 else { throw Failure.exhausted }
      epoch += 1
      try await transport.start(epoch: epoch, muted: muted)
      state = muted ? .held : .publishing
    }
  }
#endif
