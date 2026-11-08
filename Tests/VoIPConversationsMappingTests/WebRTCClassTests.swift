import Foundation
import Testing

@testable import VoIPConversationsMapping

@Suite("WebRTC class resolution")
struct WebRTCClassTests {
  @Test(arguments: WebRTCClass.allCases)
  func prefersLiveKit(kind: WebRTCClass) throws {
    var names: [String] = []
    let resolved: AnyClass = try kind.resolve { name in
      names.append(name)
      return name.hasPrefix("LK") ? NSString.self : NSObject.self
    }
    #expect(resolved === NSString.self)
    #expect(names == ["LK\(kind.rawValue)"])
  }

  @Test(arguments: WebRTCClass.allCases)
  func fallsBackToUnprefixed(kind: WebRTCClass) throws {
    var names: [String] = []
    let resolved: AnyClass = try kind.resolve { name in
      names.append(name)
      return name == kind.rawValue ? NSObject.self : nil
    }
    #expect(resolved === NSObject.self)
    #expect(names == ["LK\(kind.rawValue)", kind.rawValue])
  }

  @Test(arguments: WebRTCClass.allCases)
  func missingClassesThrow(kind: WebRTCClass) {
    var names: [String] = []
    #expect(throws: WebRTCClass.Missing(kind: kind)) {
      try kind.resolve { name in
        names.append(name)
        return nil
      }
    }
    #expect(names == ["LK\(kind.rawValue)", kind.rawValue])
  }
}
