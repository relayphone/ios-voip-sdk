#if os(iOS) && targetEnvironment(simulator)
  import CKSimProtocol
  import Foundation
  import Testing

  extension RuntimeSuites {
    /// Incoming reports that the system filters, as Do Not Disturb does, and the injected
    /// incoming-call error 4. The app's report completion receives the error.
    @Suite @MainActor struct FilteredReports {
      private static let domain = "com.apple.CallKit.error.incomingcall"
      private let runtime: Runtime
      private let app: CallKitApp

      init() throws {
        runtime = try Runtime.shared()
        app = CallKitApp()
      }

      /// Selects a filter and checks the runtime's acknowledgement.
      private func filter(_ reason: ControlRequest.FilterReason) async throws {
        let response = try await runtime.send(.incomingFilter(reason))
        guard case .incomingFilter(let state) = try response.get() else {
          throw RuntimeTestError("The runtime didn't return the filter")
        }
        #expect(state.reason == reason)
        let acknowledgement = try await runtime.entry("the filter to be configured") {
          $0.event == "incomingFilter.configured" && $0.requestID == response.id.uuidString
        }
        #expect(acknowledgement.reason == reason.rawValue && acknowledgement.code == state.code)
        #expect(try await runtime.status().incomingFilter == state)
      }

      private struct Attempt {
        let call: UUID
        let push: UUID
        let cursor: Int
      }

      /// Delivers a VoIP push that the app reports as `call`.
      private func report(_ call: UUID = UUID()) async throws -> Attempt {
        let cursor = try runtime.cursor()
        let push = try await runtime.push([
          "operation": .string("incoming"), "callUUID": .string(call.uuidString),
        ])
        return Attempt(call: call, push: push, cursor: cursor)
      }

      /// Waits for the report's completion and checks what the runtime and the app observed.
      @discardableResult
      private func expect(
        _ attempt: Attempt, code: Int, filterReason: String, verification: String,
        delayMS: Double? = nil, sourceLocation: SourceLocation = #_sourceLocation
      ) async throws -> Entry {
        let call = attempt.call.uuidString
        try await runtime.entry("the report's completion", after: attempt.cursor) {
          $0.event == "fixture.reportCompleted" && $0.callUUID == call
        }
        let rows = try runtime.entries(after: attempt.cursor)
        let incoming = rows.filter { $0.event == "report.incoming" && $0.callUUID == call }
        let completed = rows.filter { $0.event == "report.completed" && $0.callUUID == call }
        let callbacks = rows.filter { $0.event == "fixture.reportCompleted" && $0.callUUID == call }
        try #require(
          incoming.count == 1 && completed.count == 1 && callbacks.count == 1,
          "One report and one completion", sourceLocation: sourceLocation)
        let (entry, done, callback) = (incoming[0], completed[0], callbacks[0])
        #expect(
          entry.reportID != nil && entry.reportID == done.reportID, sourceLocation: sourceLocation)
        let domain = code == 0 ? "" : Self.domain
        for row in [entry, done] {
          #expect(row.code == code && row.domain == domain, sourceLocation: sourceLocation)
          #expect(
            row.filterReason == filterReason && row.verification == verification,
            sourceLocation: sourceLocation)
          #expect(row.pushID == attempt.push.uuidString, sourceLocation: sourceLocation)
        }
        #expect(entry.latencyMS == 0 && done.error == code, sourceLocation: sourceLocation)
        #expect(callback.code == code && callback.domain == domain, sourceLocation: sourceLocation)
        #expect(
          callback.replyCount == 1 && callback.main == true && callback.handle == CallKitApp.handle,
          sourceLocation: sourceLocation)
        #expect(
          entry.time <= done.time && done.time <= callback.time, sourceLocation: sourceLocation)
        if let delayMS {
          // Timers never fire early; allow for the journal's millisecond rounding.
          #expect((done.latencyMS ?? 0) >= delayMS - 150, sourceLocation: sourceLocation)
          #expect((callback.latencyMS ?? 0) >= delayMS - 150, sourceLocation: sourceLocation)
          #expect(Double(done.time - entry.time) >= delayMS - 150, sourceLocation: sourceLocation)
        }
        for event in ["push.completed", "push.callbackReturned"] {
          let observed = rows.filter { $0.event == event && $0.pushID == attempt.push.uuidString }
          #expect(
            observed.count == 1 && observed.first?.reportEntered == true, "\(event)",
            sourceLocation: sourceLocation)
        }
        #expect(
          !rows.contains {
            $0.event == "diagnostic.pushReportingViolation"
              || $0.event == "diagnostic.pushReportExpired"
          }, sourceLocation: sourceLocation)
        if code != 0 { try expectNoCall(after: attempt.cursor, sourceLocation: sourceLocation) }
        return entry
      }

      /// Checks that a rejected report created no call, action or audio. Actions issued earlier,
      /// such as CallKit's unmute after a call ends, may still expire.
      private func expectNoCall(after cursor: Int, sourceLocation: SourceLocation) throws {
        let entries = try runtime.entries()
        let earlier = Set(
          entries.prefix(cursor).filter { $0.event == "action.deadline" }.compactMap(\.actionID))
        for row in entries.dropFirst(cursor) {
          let expiry =
            (row.event == "action.expired" || row.event == "action.timeout")
            && earlier.contains(row.actionID ?? "")
          #expect(
            !["call.changed", "audio.activated", "fault.audioSuppressed", "transaction.delivered"]
              .contains(row.event) && (!row.event.hasPrefix("action.") || expiry),
            "\(row.event)", sourceLocation: sourceLocation)
        }
      }

      /// Checks that the runtime has no call, pending action or audio.
      private func expectIdle(
        filter: ControlRequest.FilterReason? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
      ) async throws {
        let status = try await runtime.status()
        #expect(
          status.calls.isEmpty && status.pending == 0 && !status.audioActive,
          sourceLocation: sourceLocation)
        if let filter {
          #expect(status.incomingFilter.reason == filter, sourceLocation: sourceLocation)
        }
      }

      @Test(arguments: [
        (ControlRequest.FilterReason.restrictedSharingMode, 5),
        (.callIsProtected, 6), (.sensitiveParticipants, 7),
      ])
      func unverifiedFiltersRejectTheReportAfterTheMeasuredDelay(
        reason: ControlRequest.FilterReason, code: Int
      ) async throws {
        defer { app.stop() }
        try await runtime.clearSettings()
        try await filter(reason)
        try await expect(
          report(), code: code, filterReason: reason.rawValue, verification: "unverified",
          delayMS: 2070)
        try await expectIdle(filter: reason)
        try await runtime.clearSettings()
      }

      @Test func doNotDisturbFiltersEveryCallFromTheSameNumberAndTheAppSurvives() async throws {
        defer { app.stop() }
        try await runtime.clearSettings()
        try await filter(.doNotDisturb)
        let first = try await expect(
          report(), code: 3, filterReason: "do-not-disturb", verification: "verified",
          delayMS: 2070)
        // Past PushKit's deadline for reporting, the same process still answers its mailbox.
        try await Task.sleep(for: .milliseconds(4600))
        try await expectIdle(filter: .doNotDisturb)
        // Filtering grants no repeated-caller exception.
        let repeated = try await expect(
          report(), code: 3, filterReason: "do-not-disturb", verification: "verified",
          delayMS: 2070)
        #expect(repeated.time - first.time >= 4600)
        try await expectIdle(filter: .doNotDisturb)
        try await runtime.clearSettings()
      }

      @Test func aReportKeepsTheSettingsItEnteredWith() async throws {
        defer { app.stop() }
        try await runtime.clearSettings()
        try await runtime.control(.faults([.incomingErrorCode(4), .reportCallbackDelayMS(5000)]))
        let attempt = try await report()
        let entered = try await runtime.entry("the report to enter", after: attempt.cursor) {
          $0.event == "report.incoming" && $0.pushID == attempt.push.uuidString
        }
        // Changes while the report is pending apply only to later reports.
        let filterRequest = try await runtime.send(.incomingFilter(.restrictedSharingMode))
        let faultRequest = try await runtime.send(
          .faults([.incomingErrorCode(0), .reportCallbackDelayMS(1000)]))
        #expect(try faultRequest.get() == .faults(incomingErrorCode: 0))
        try await expect(
          attempt, code: 4, filterReason: "none", verification: "injected-fault", delayMS: 5020)
        let rows = try runtime.entries(after: attempt.cursor)
        let done = try #require(
          rows.first { $0.event == "report.completed" && $0.reportID == entered.reportID })
        for (event, request) in [
          ("incomingFilter.configured", filterRequest.id), ("faults.configured", faultRequest.id),
        ] {
          let change = try #require(
            rows.first { $0.event == event && $0.requestID == request.uuidString })
          #expect(entered.sequence < change.sequence && change.sequence < done.sequence)
        }
        try await runtime.clearSettings()
        try await expectIdle()
      }

      @Test func clearingTheFilterAdmitsCallsAndADuplicateStillFailsWithCodeTwo() async throws {
        defer { app.stop() }
        try await runtime.clearSettings()
        let admitted = try await report()
        try await expect(admitted, code: 0, filterReason: "none", verification: "not-applicable")
        try await runtime.until("the admitted call") {
          try await runtime.status().calls.contains { $0.state.uuid == admitted.call } ? true : nil
        }
        try await filter(.doNotDisturb)
        let duplicate = try await report(admitted.call)
        try await expect(duplicate, code: 2, filterReason: "none", verification: "not-applicable")
        #expect(try await runtime.status().calls.map(\.state.uuid) == [admitted.call])
        try await runtime.clearSettings()
        try await runtime.end([admitted.call])
      }
    }
  }
#endif
