import Foundation
#if SWIFT_PACKAGE
import VoIPPlatform
#endif

enum ProcessSDKOwnership {
  // Swift globals include their module identity. Unlike an Objective-C class
  // static, two linked SDK images retain distinct tokens even if the runtime
  // coalesces their identically named platform helper class.
  private static let token = UUID().uuidString

  static func claim() throws(VoIPStartupError) {
    guard SDKProcessOwnership.claim(moduleIdentity: String(reflecting: Self.self), ownerToken: token) else {
      throw VoIPStartupError.duplicateSDKLinkage
    }
  }
}
