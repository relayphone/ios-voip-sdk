#if os(iOS) && targetEnvironment(simulator)
  @preconcurrency import CallKit
  import CKSimProtocol
  import Foundation
  @preconcurrency import LiveCommunicationKit
  import Testing

  extension RuntimeSuites {
    @Suite @MainActor struct VideoObservations {
      @Test func callKitReportsConfirmVideoAndFreezeEndedHistory() async throws {
        try await withCallKitApp { app in
          let runtime = try Runtime.shared()
          try await runtime.clearSettings()
          let id = UUID()
          app.ring(id)
          try await runtime.until("the incoming report") {
            try await runtime.status().calls.contains { $0.state.uuid == id } ? true : nil
          }
          let cursor = try runtime.cursor()
          let update = CXCallUpdate()
          update.hasVideo = true
          app.provider.reportCall(with: id, updated: update)
          app.provider.reportCall(with: id, updated: update)
          app.provider.reportCall(with: UUID(), updated: update)
          let unrelated = CXProvider(configuration: CXProviderConfiguration())
          let downgrade = CXCallUpdate()
          downgrade.hasVideo = false
          unrelated.reportCall(with: id, updated: downgrade)
          unrelated.invalidate()
          let snapshot = try await runtime.status()
          #expect(snapshot.calls.first { $0.state.uuid == id }?.state.hasVideo == true)
          #expect(snapshot.retainedCalls.first { $0.uuid == id }?.videoChanges.count == 1)
          #expect(try runtime.entries(after: cursor).count { $0.event == "call.videoChanged" } == 1)
          app.provider.reportCall(with: id, updated: downgrade)
          let voice = try await runtime.status()
          #expect(voice.calls.first { $0.state.uuid == id }?.state.hasVideo == false)
          let history = try #require(voice.retainedCalls.first { $0.uuid == id }?.videoChanges)
          #expect(history.map(\.hasVideo) == [true, false])
          app.provider.reportCall(with: id, endedAt: .now, reason: .remoteEnded)
          app.provider.reportCall(with: id, updated: update)
          let ended = try await runtime.status()
          #expect(ended.retainedCalls.first { $0.uuid == id }?.videoChanges == history)
          #expect(ended.retainedCalls.first { $0.uuid == id }?.hasVideo == false)
        }
      }
      @Test func outgoingRequestDoesNotPredictVideoOrReuseEndedHistory() async throws {
        try await withCallKitApp { app in
          let runtime = try Runtime.shared()
          try await runtime.clearSettings()
          let id = UUID()
          app.ring(id)
          let update = CXCallUpdate()
          update.hasVideo = true
          app.provider.reportCall(with: id, updated: update)
          app.provider.reportCall(with: id, endedAt: .now, reason: .remoteEnded)
          let start = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: "video"))
          start.isVideo = true
          try await withCheckedThrowingContinuation {
            (reply: CheckedContinuation<Void, any Error>) in
            app.controller.request(CXTransaction(action: start)) { error in
              if let error { reply.resume(throwing: error) } else { reply.resume() }
            }
          }
          let status = try await runtime.status()
          #expect(status.calls.first { $0.state.uuid == id }?.state.hasVideo == false)
          #expect(status.retainedCalls.first { $0.uuid == id }?.videoChanges.isEmpty == true)
          try await runtime.end([id])
        }
      }
      @Test func liveCommunicationKitCapabilitiesConfirmVideo() async throws {
        try await withLCKSession(supportsVideo: true) { session in
          let app = session.app
          try await app.reportIncoming("video")
          let id = app.id("video")
          try app.update("video", capabilities: [.video, .pausing])
          let enabled = try await session.runtime.until("confirmed LCK video") {
            let status = try await session.runtime.status()
            return status.calls.first { $0.state.uuid == id }?.state.hasVideo == true ? status : nil
          }
          #expect(
            enabled.retainedCalls.first { $0.uuid == id }?.videoChanges.map(\.hasVideo) == [true])
          try app.update("video", capabilities: [.video, .pausing])
          try app.update("video", capabilities: [.pausing])
          let voice = try await session.runtime.until("confirmed LCK audio") {
            let status = try await session.runtime.status()
            return status.calls.first { $0.state.uuid == id }?.state.hasVideo == false
              ? status : nil
          }
          #expect(
            voice.retainedCalls.first { $0.uuid == id }?.videoChanges.map(\.hasVideo) == [
              true, false,
            ])
        }
      }
    }
  }
#endif
