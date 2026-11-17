import CKSimProtocol
import Foundation
import Testing

struct ExecutionScenarioTests {
  @Test func unknownFixtureFieldsAreRefusedInsteadOfDiscarded() throws {
    let json =
      #"{"id":"11111111-1111-4111-8111-111111111111","lock":"locked","activity":"background","coverage":"explicitAdapters","applicationAllowanceMS":5000,"sdkPushAllowanceMS":2000,"pushWakeAllowanceMS":5000}"#
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(ExecutionScenarioConfiguration.self, from: Data(json.utf8))
    }
  }
  @Test func typedConfigurationAndStatusResponseRoundTrip() throws {
    let identity = try RuntimeIdentity(bundleID: "example.calls", runID: "test", pid: 42)
    let config = try ExecutionScenarioConfiguration(
      id: UUID(), lock: .locked, activity: .background,
      coverage: .explicitAdapters, applicationAllowanceMS: 5000, sdkPushAllowanceMS: 2000)
    let request = try ControlRequest(
      id: UUID(), target: identity, operation: .executionScenario(config))
    #expect(try ControlRequest.decode(JSONEncoder().encode(request)) == request)
    let decision = ExecutionDecisionSnapshot(
      configuration: config, assessedAt: 100,
      eligibility: .suspendEligible, reasons: [])
    var snapshot = try JSONDecoder().decode(
      RuntimeSnapshot.self,
      from: Data(
        #"{"calls":[],"pending":0,"audioActive":false,"sequence":1,"incomingErrorCode":0,"incomingFilter":{"reason":"none","code":0,"verification":"not-applicable"},"providerConfigurations":[]}"#
          .utf8))
    #expect(snapshot.executionDecision == nil)
    snapshot.executionDecision = decision
    let result = ControlResult.status(snapshot)
    #expect(
      try JSONDecoder().decode(ControlResult.self, from: JSONEncoder().encode(result)) == result)
  }
  @Test(arguments: ["0", "120001", "1.5", "1e3", "null", "true"])
  func invalidFixtureAllowancesRejectBeforeDispatch(value: String) throws {
    let json =
      #"{"id":"11111111-1111-4111-8111-111111111111","runID":"test","pid":42,"bundleID":"example.calls","operation":"execution-scenario","scenario":{"id":"11111111-1111-4111-8111-111111111111","lock":"locked","activity":"background","coverage":"explicitAdapters","applicationAllowanceMS":\#(value),"sdkPushAllowanceMS":2000}}"#
    #expect(throws: (any Error).self) { try ControlRequest.decode(Data(json.utf8)) }
  }
}
