import Foundation
import Testing
import VoIPCore

@Suite struct FrameworkErrorTests {
  private let requestTransaction = "com.apple.CallKit.error.requesttransaction"

  @Test func keepsTheDomainAndCodeOfEveryWrappedError() {
    let callService = NSError(domain: requestTransaction, code: 1)
    let framework = NSError(
      domain: "Framework", code: 2, userInfo: [NSUnderlyingErrorKey: callService])
    let error = FrameworkError(framework)
    #expect(
      error
        == FrameworkError(
          domain: "Framework", code: 2,
          underlyingErrors: [FrameworkError(domain: requestTransaction, code: 1)]))
    #expect(error.description == "Framework 2 (\(requestTransaction) 1)")
  }

  @Test func keepsSeveralWrappedErrors() {
    let error = NSError(
      domain: "Framework", code: 2,
      userInfo: [
        NSMultipleUnderlyingErrorsKey: [
          NSError(domain: "A", code: 1), NSError(domain: "B", code: 3),
        ]
      ])
    #expect(FrameworkError(error).description == "Framework 2 (A 1, B 3)")
  }

  @Test func keepsAFewLevels() {
    var error = NSError(domain: "Level", code: 0)
    for level in 1...6 {
      error = NSError(domain: "Level", code: level, userInfo: [NSUnderlyingErrorKey: error])
    }
    #expect(FrameworkError(error).description == "Level 6 (Level 5 (Level 4 (Level 3)))")
  }

  @Test func describesSwiftErrors() {
    let error = FrameworkError(CancellationError())
    #expect(error.underlyingErrors.isEmpty)
    #expect(!error.domain.isEmpty)
  }
}
