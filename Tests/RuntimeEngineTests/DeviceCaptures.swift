import CryptoKit
import Foundation
import Testing

@testable import CKSimRuntime

/// The repository checkout that contains these tests.
let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent()

/// The `ios-27.0` behaviour profile's source file.
let profileFile = repository.appending(path: "Sources/Engine/Resources/ios-27.0.json")

/// The profile as the runtime decodes it.
func behaviorProfile() throws -> BehaviorProfile {
  try JSONDecoder().decode(BehaviorProfile.self, from: Data(contentsOf: profileFile))
}

/// The profile as a JSON object, for the fields the runtime doesn't decode.
func profileObject() throws -> [String: Any] {
  try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: profileFile)) as? [String: Any])
}

func sha256(_ path: String) throws -> String {
  let data = try Data(contentsOf: repository.appending(path: path))
  return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// One row of a multi-call capture from the iPhone 13 with iOS 27.0, made by an app that uses
/// LiveCommunicationKit only.
struct CaptureRow: Decodable {
  struct Conversation: Decodable {
    let uuid: String
    let state: String
  }

  let event: String
  let monoMS: Int64
  let kind: String?
  /// The capture's name for the conversation: A, B, C or D.
  let conv: String?
  let conversation: String?
  let action: String?
  let failed: Bool?
  let state: String?
  let isPaused: Bool?
  /// Milliseconds from delivery to the action's advertised `timeoutDate`.
  let timeoutIn: Int?
  let code: Int?
  let domain: String?
  let label: String?
  let capabilities: [String]?
  let conversations: [Conversation]?

  private enum CodingKeys: String, CodingKey {
    case event, kind, conv, conversation, action, failed, state, isPaused, timeoutIn, code, domain
    case label, capabilities, conversations
    case monoMS = "mono_ms"
  }

  var isTerminal: Bool { event == "lckmulti.settled" || event == "lckmulti.timedOut" }
  var succeeded: Bool { event == "lckmulti.settled" && failed != true }
}

/// The rows of `docs/research/callkit-simulator-probe/livecommunicationkit/multicall/<name>.jsonl`.
func multiCallCapture(_ name: String) throws -> [CaptureRow] {
  let file = repository.appending(
    path: "docs/research/callkit-simulator-probe/livecommunicationkit/multicall/\(name).jsonl")
  return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
    try JSONDecoder().decode(CaptureRow.self, from: Data($0.utf8))
  }
}
