import Foundation
import Testing

@testable import CKSimRuntime

/// The `ios-27.0` behaviour profile, its evidence and the runtime's validation of it.
struct BehaviorProfileTests {
  @Test func theRuntimeAcceptsTheProfile() throws {
    #expect(try behaviorProfile().refusal(as: "ios-27.0") == nil)
    #expect(try behaviorProfile().refusal(as: "ios-28.0") != nil)
  }

  @Test func theEmbeddedProfileIsTheProfileFile() throws {
    let file = try String(contentsOf: profileFile, encoding: .utf8)
    #expect(BehaviorProfile.embeddedJSON == file.trimmingCharacters(in: .newlines))
  }

  private static let timings = [
    "lckActionDeadlineSeconds", "answerExpirySeconds", "pushReportDeadlineSeconds",
    "lckMultiCall.pauseEndExpirySeconds", "lckMultiCall.joinExpirySeconds",
    "lckMultiCall.cleanupEndExpirySeconds", "lckMultiCall.pausedAfterDeliverySeconds",
    "lckMultiCall.joinedAfterSettlementSeconds", "lckMultiCall.audioHandoffGapSeconds",
    "lckMultiCall.audioDeactivationAfterDeliverySeconds", "lckMultiCall.appResumeEndDelaySeconds",
  ]

  @Test(arguments: timings, ["0", "-1", "\"Infinity\"", "\"-Infinity\"", "\"NaN\""])
  func theRuntimeRefusesATimingThatIsntPositiveAndFinite(key: String, value: String) throws {
    var profile = try profileObject()
    let replacement =
      try JSONSerialization.jsonObject(
        with: Data("[\(value)]".utf8), options: []) as? [Any]
    let parts = key.split(separator: ".").map(String.init)
    if parts.count == 1 {
      profile[key] = replacement?.first
    } else {
      var nested = try #require(profile[parts[0]] as? [String: Any])
      nested[parts[1]] = replacement?.first
      profile[parts[0]] = nested
    }
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
      positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
    let decoded = try decoder.decode(
      BehaviorProfile.self, from: JSONSerialization.data(withJSONObject: profile))
    #expect(decoded.refusal(as: "ios-27.0") != nil)
  }

  @Test func theRuntimeRefusesAFilterPolicyThatDisagreesWithItsReason() throws {
    var profile = try profileObject()
    var policies = try #require(profile["incomingFilterPolicies"] as? [String: Any])
    var doNotDisturb = try #require(policies["do-not-disturb"] as? [String: Any])
    doNotDisturb["verification"] = "unverified"
    policies["do-not-disturb"] = doNotDisturb
    profile["incomingFilterPolicies"] = policies
    let decoded = try JSONDecoder().decode(
      BehaviorProfile.self, from: JSONSerialization.data(withJSONObject: profile))
    #expect(decoded.refusal(as: "ios-27.0") == "invalid incoming filter profile")
  }

  @Test func everyCitedCaptureIsInTheRepositoryUnchanged() throws {
    let profile = try profileObject()
    var digests: [String: String] = [:]
    let deadline = try #require(profile["lckActionDeadlineEvidence"] as? [String: Any])
    for (path, capture) in try #require(deadline["captures"] as? [String: [String: Any]]) {
      digests[path] = capture["sha256"] as? String
    }
    let multiCall = try #require(profile["lckMultiCall"] as? [String: Any])
    digests.merge(try #require(multiCall["captureSHA256"] as? [String: String])) { $1 }
    let push = try #require(profile["pushReportDeadlineEvidence"] as? [String: Any])
    digests.merge(try #require(push["captures"] as? [String: String])) { $1 }
    let blocked = try #require(profile["lckBlockedNumberEvidence"] as? [String: Any])
    digests.merge(try #require(blocked["captures"] as? [String: String])) { $1 }

    #expect(digests.count == 26)
    for (path, digest) in digests {
      #expect(try sha256(path) == digest, "\(path)")
    }
  }

  @Test func everyCitedDocumentIsInTheRepository() throws {
    let profile = try behaviorProfile()
    let object = try profileObject()
    let multiCall = try #require(object["lckMultiCall"] as? [String: Any])
    let push = try #require(object["pushReportDeadlineEvidence"] as? [String: Any])
    let documents = Set(profile.incomingFilterPolicies.values.flatMap(\.evidence)).union([
      try #require(multiCall["source"] as? String), try #require(push["reference"] as? String),
    ])
    for document in documents {
      #expect(
        FileManager.default.fileExists(atPath: repository.appending(path: document).path()),
        "\(document)")
    }
  }

  @Test func theMultiCallPolicyNamesWhatWasntMeasured() throws {
    let multiCall = try #require(profileObject()["lckMultiCall"] as? [String: Any])
    #expect(multiCall["verification"] as? String == "measured")
    #expect((multiCall["unverified"] as? [String])?.isEmpty == false)
  }

  @Test func blockedNumbersWereMeasuredToRing() throws {
    let blocked = try #require(profileObject()["lckBlockedNumberEvidence"] as? [String: Any])
    #expect(blocked["verification"] as? String == "measured-negative")
    #expect(blocked["incomingErrorCode"] as? Int == 0)
    #expect(blocked["repeatAfterSeconds"] as? Int == 66)
  }
}
