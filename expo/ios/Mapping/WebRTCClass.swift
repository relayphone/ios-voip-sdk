import Foundation

/// WebRTC's audio classes have an LK prefix in LiveKitWebRTC builds.
enum WebRTCClass: String, CaseIterable, Sendable {
  case audioSession = "RTCAudioSession"
  case configuration = "RTCAudioSessionConfiguration"

  struct Missing: Error, Equatable, CustomStringConvertible {
    let kind: WebRTCClass

    var description: String {
      "Neither LK\(kind.rawValue) nor \(kind.rawValue) is linked; include a WebRTC build or use mediaAdapter: none"
    }
  }

  func resolve(using lookup: (String) -> AnyClass? = NSClassFromString) throws(Missing) -> AnyClass
  {
    guard let type = lookup("LK\(rawValue)") ?? lookup(rawValue) else {
      throw Missing(kind: self)
    }
    return type
  }
}
