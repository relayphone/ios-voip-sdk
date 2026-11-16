import Foundation

#if SWIFT_PACKAGE
  import VoIPCore
#endif
#if canImport(AVFoundation)
  import AVFoundation
#endif
#if canImport(AVFAudio)
  import AVFAudio
#endif

/// Media access requested explicitly by the app's foreground UI.
enum MediaKind: String, CaseIterable, Sendable { case microphone, camera }

struct MediaPermissionResponse: Equatable, Sendable {
  enum Status: String, Sendable { case granted, denied, undetermined }
  let status: Status
  var granted: Bool { status == .granted }
  var canAskAgain: Bool { status == .undetermined }
  var json: JSONValue {
    .object([
      "status": .string(status.rawValue), "granted": .bool(granted),
      "canAskAgain": .bool(canAskAgain), "expires": .string("never"),
    ])
  }
  #if canImport(AVFoundation)
    init(camera: AVAuthorizationStatus) {
      status =
        switch camera {
        case .notDetermined: .undetermined
        case .authorized: .granted
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }
  #endif
  #if canImport(AVFAudio)
    init(microphone: AVAudioApplication.recordPermission) {
      status =
        switch microphone {
        case .undetermined: .undetermined
        case .granted: .granted
        case .denied: .denied
        @unknown default: .denied
        }
    }
  #endif
  init(status: Status) { self.status = status }
}

/// Readiness is a snapshot, never a request or a reason to activate call audio.
struct MediaPermissions: Sendable {
  let microphone: MediaPermissionResponse
  let camera: MediaPermissionResponse
  var json: JSONValue { .object(["microphone": microphone.json, "camera": camera.json]) }
  func readiness(isVideo: Bool) -> JSONValue {
    let required: [MediaKind] = isVideo ? [.microphone, .camera] : [.microphone]
    let missing = required.filter { ($0 == .microphone ? microphone : camera).granted == false }
    return .object([
      "required": .array(required.map { .string($0.rawValue) }),
      "missing": .array(missing.map { .string($0.rawValue) }),
    ])
  }
}

/// Injected OS access keeps mapping and foreground gating testable without permission dialogs.
@MainActor
struct MediaPermissionAccess {
  let foreground: () -> Bool
  let read: (MediaKind) -> MediaPermissionResponse
  let prompt: (MediaKind) async -> Void
  func get() -> MediaPermissions {
    MediaPermissions(microphone: read(.microphone), camera: read(.camera))
  }
  func readiness(for call: Call?) throws(CommandError) -> JSONValue {
    guard let call else { throw .unknownConversation }
    return get().readiness(isVideo: call.hasVideo)
  }
  func request(_ kinds: [MediaKind]) async throws(CommandError) -> MediaPermissions {
    guard foreground() else { throw .notForeground }
    var requested: Set<MediaKind> = []
    for kind in kinds where requested.insert(kind).inserted {
      guard read(kind).canAskAgain else { continue }
      // The app may have left the foreground while the previous dialog was open.
      guard foreground() else { throw .notForeground }
      await prompt(kind)
    }
    return get()
  }
}
