import AVFAudio
import AVFoundation
import Testing
import VoIPCore

@testable import VoIPConversationsMapping

@Suite("Explicit media permissions")
struct MediaPermissionsTests {
  @Test func everyCameraStatusHasExpoSemantics() {
    for (native, status) in [
      (AVAuthorizationStatus.notDetermined, MediaPermissionResponse.Status.undetermined),
      (.authorized, .granted), (.denied, .denied), (.restricted, .denied),
    ] {
      let result = MediaPermissionResponse(camera: native)
      #expect(result.status == status)
      #expect(result.granted == (status == .granted))
      #expect(result.canAskAgain == (status == .undetermined))
      #expect(result.json["expires"] == .string("never"))
    }
  }
  @Test func everyRecordPermissionHasExpoSemantics() {
    for (native, status) in [
      (
        AVAudioApplication.recordPermission.undetermined,
        MediaPermissionResponse.Status.undetermined
      ),
      (.denied, .denied), (.granted, .granted),
    ] {
      let result = MediaPermissionResponse(microphone: native)
      #expect(result.status == status)
      #expect(result.granted == (status == .granted))
      #expect(result.canAskAgain == (status == .undetermined))
      #expect(result.json["expires"] == .string("never"))
    }
  }
  @Test @MainActor func queriesNeverPromptAndRequestsOnlyAskUndeterminedKindsOnce() async throws {
    var states: [MediaKind: MediaPermissionResponse.Status] = [
      .microphone: .granted, .camera: .undetermined,
    ]
    var prompts: [MediaKind] = []
    let access = MediaPermissionAccess(
      foreground: { true }, read: { MediaPermissionResponse(status: states[$0]!) },
      prompt: {
        prompts.append($0)
        states[$0] = .denied
      })
    #expect(access.get().camera.canAskAgain)
    #expect(prompts.isEmpty)
    let result = try await access.request([.microphone, .camera, .camera])
    #expect(prompts == [.camera])
    #expect(result.camera.status == .denied)
    _ = try await access.request([.camera, .microphone])
    #expect(prompts == [.camera])
  }
  @Test @MainActor func backgroundRequestsRejectEvenWhenEmptyAndRecheckBetweenDialogs() async throws
  {
    var foreground = false
    var prompts: [MediaKind] = []
    let access = MediaPermissionAccess(
      foreground: { foreground },
      read: { _ in MediaPermissionResponse(status: .undetermined) },
      prompt: {
        prompts.append($0)
        foreground = false
      })
    for kinds in [[], [MediaKind.microphone]] {
      do {
        _ = try await access.request(kinds)
        Issue.record("Background request accepted")
      } catch { #expect(error.code == .notForeground) }
    }
    #expect(prompts.isEmpty)
    #expect(access.get().microphone.status == .undetermined)
    foreground = true
    do {
      _ = try await access.request([.microphone, .camera])
      Issue.record("Second background prompt accepted")
    } catch { #expect(error.code == .notForeground) }
    #expect(prompts == [.microphone])
  }
  @Test @MainActor func unknownReadinessRejectsAndKnownCallsNeverPromptInBackground() throws {
    var reads = 0
    let access = MediaPermissionAccess(
      foreground: { false },
      read: { _ in
        reads += 1
        return MediaPermissionResponse(status: .denied)
      },
      prompt: { _ in Issue.record("Readiness prompted") })
    do {
      _ = try access.readiness(for: nil)
      Issue.record("Unknown call accepted")
    } catch { #expect(error.code == .unknownConversation) }
    #expect(reads == 0)
    for video in [false, true] {
      let call = Call(
        id: CallID(rawValue: "call"), isIncoming: true, parties: [], status: .ringing,
        hasVideo: video)
      #expect(
        try access.readiness(for: call)["required"]
          == .array(video ? [.string("microphone"), .string("camera")] : [.string("microphone")]))
    }
  }

  @Test func readinessRequiresCameraOnlyForVideoAndReportsEveryMissingKind() {
    for microphone in [MediaPermissionResponse.Status.granted, .denied, .undetermined] {
      for camera in [MediaPermissionResponse.Status.granted, .denied, .undetermined] {
        let permissions = MediaPermissions(
          microphone: .init(status: microphone), camera: .init(status: camera))
        for video in [false, true] {
          let result = permissions.readiness(isVideo: video)
          #expect(
            result["required"]
              == .array(
                video ? [.string("microphone"), .string("camera")] : [.string("microphone")]))
          var missing: [JSONValue] = []
          if microphone != .granted { missing.append(.string("microphone")) }
          if video && camera != .granted { missing.append(.string("camera")) }
          #expect(result["missing"] == .array(missing))
        }
      }
    }
  }
}
