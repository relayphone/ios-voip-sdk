import Foundation
import Testing

@testable import VoIPSDK

struct BundleDecodingTests {
  @Test func defaultsMatchTheConfigPlugin() throws {
    let value = try decode("")
    #expect(
      value.maximumConversationGroups == 2 && value.maximumConversationsPerConversationGroup == 2)
    #expect(value.supportsVideo && value.includesCallsInRecents && value.simulatorSupport)
    #expect(value.unhandledAction == .fail)
    #expect(value.ringtoneName == nil && value.iconTemplateImageName == nil)
  }

  @Test func overridesKeepTheirPlistTypes() throws {
    let value = try decode(
      """
      <key>maximumConversationGroups</key><integer>9223372036854775807</integer>
      <key>maximumConversationsPerConversationGroup</key><integer>3</integer>
      <key>supportsVideo</key><false/><key>includesCallsInRecents</key><false/>
      <key>simulatorSupport</key><false/>
      <key>unhandledAction</key><string>accept</string>
      <key>ringtoneName</key><string>ring.caf</string><key>iconTemplateImageName</key><string>Phone</string>
      """)
    #expect(
      value.maximumConversationGroups == Int.max
        && value.maximumConversationsPerConversationGroup == 3)
    #expect(!value.supportsVideo && !value.includesCallsInRecents && !value.simulatorSupport)
    #expect(value.unhandledAction == .accept)
    #expect(value.ringtoneName == "ring.caf" && value.iconTemplateImageName == "Phone")
  }

  @Test(arguments: [
    "<key>supportsVideo</key><integer>1</integer>",
    "<key>simulatorSupport</key><string>true</string>",
    "<key>maximumConversationGroups</key><true/>",
    "<key>maximumConversationGroups</key><integer>0</integer>",
    "<key>maximumConversationsPerConversationGroup</key><integer>-1</integer>",
    "<key>maximumConversationGroups</key><real>2.5</real>",
    "<key>maximumConversationGroups</key><real>inf</real>",
    "<key>unhandledAction</key><string>futurePolicy</string>",
    "<key>ringtoneName</key><integer>1</integer>",
  ])
  func invalidTypesAndRangesAreRejected(contents: String) {
    #expect(throws: (any Error).self) { try decode(contents) }
  }

  private func decode(_ contents: String) throws -> VoIPBundleConfiguration {
    let data = Data("<plist version=\"1.0\"><dict>\(contents)</dict></plist>".utf8)
    return try PropertyListDecoder().decode(VoIPBundleConfiguration.self, from: data)
  }
}
