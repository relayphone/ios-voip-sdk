import AVFAudio
import AVFoundation
import UIKit

extension MediaPermissionAccess {
  /// Queries never activate the audio session or request access as a side effect.
  static var system: Self {
    Self(
      foreground: { UIApplication.shared.applicationState == .active },
      read: { kind in
        switch kind {
        case .camera:
          MediaPermissionResponse(camera: AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
          MediaPermissionResponse(microphone: AVAudioApplication.shared.recordPermission)
        }
      },
      prompt: { kind in
        switch kind {
        case .camera: _ = await AVCaptureDevice.requestAccess(for: .video)
        case .microphone: _ = await AVAudioApplication.requestRecordPermission()
        }
      })
  }
}
