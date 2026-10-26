import AppIntents
import ExtensionFoundation
import Foundation

@main struct FocusFilterExtension: AppIntentsExtension {}

enum AIPolicy: String, AppEnum {
  case decline, screenWithAI
  static var typeDisplayRepresentation: TypeDisplayRepresentation = "AI call policy"
  static var caseDisplayRepresentations: [AIPolicy: DisplayRepresentation] = [
    .decline: "Decline", .screenWithAI: "AI screens calls"]
}

struct FocusPolicyIntent: SetFocusFilterIntent {
  static var title: LocalizedStringResource = "AI call policy"
  @Parameter(title: "Policy", default: .decline) var policy: AIPolicy
  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "AI policy: \(policy.rawValue)") }
  func perform() async throws -> some IntentResult {
    let defaults = UserDefaults(suiteName: "group.dev.callkitsim.focus")!
    defaults.set(policy.rawValue, forKey: "focus.aiPolicy")
    defaults.set(Date().timeIntervalSince1970, forKey: "focus.policyUpdatedAt")
    return .result()
  }
}
