#if os(macOS)
  import ArgumentParser
  import CKSimProtocol
  import Foundation
  import Synchronization
  import Testing

  @testable import CKSimTool

  /// `cksim`'s commands against a fake simulator and a fake runtime mailbox.
  struct CommandTests {
    @Test func sharedOptionsMayComeBeforeTheCommand() {
      #expect(
        CKSim.arguments(["--simulator", device, "--bundle=x", "--timeout", "2", "status", "--json"])
          == ["status", "--simulator", device, "--bundle=x", "--timeout", "2", "--json"])
      #expect(
        CKSim.arguments(["answer", "--bundle", "x", "id"]) == ["answer", "--bundle", "x", "id"])
    }

    @Test(arguments: [
      ["tones", call.uuidString, "--digits", "1,2"], ["tones", call.uuidString, "--digits", "1\n"],
      ["mute", call.uuidString, "--muted", "invalid"],
      ["push", "--payload-file", "p.json", "--must-report", "true", "--launch"],
      ["install", "--app-container", "/tmp"], ["status", "--timeout", "0"],
      ["status", "--timeout", "121"], ["incoming-filter", "--reason", "block-list"],
      ["faults", "--incoming-error-code", "3"], ["watch", "--after", "-1"],
      ["watch", "--duration", "0"], ["inspect", "--app", "x.app", "--allow-shared-simulator"],
    ])
    func invalidCommandsAreRefusedBeforeAnythingRuns(command: [String]) async throws {
      let simulator = FakeSimulator()
      let result = await run(["--bundle", bundle] + command, simulator: simulator)
      #expect(result.status == ExitCode.validationFailure.rawValue)
      #expect(simulator.calls.isEmpty)
    }

    @Test func aBundleIsRequiredExceptToRestore() async throws {
      let simulator = FakeSimulator()
      #expect(await run(["status"], simulator: simulator).status != 0)
      #expect(await run(["--bundle", "a b", "status"], simulator: simulator).status != 0)
      #expect(simulator.calls.isEmpty)
    }

    @Test func faultsWithoutChangesClearEveryFault() throws {
      let command = try #require(CKSim.parseAsRoot(["faults"]) as? CKSim.Faults)
      #expect(
        command.changes == [
          .staleAudio(false), .reportCallbackDelayMS(0), .invalidateDuringHandoff(false),
          .incomingErrorCode(0),
        ])
      let partial = try #require(
        CKSim.parseAsRoot(["faults", "--incoming-error-code", "4"]) as? CKSim.Faults)
      #expect(partial.changes == [.incomingErrorCode(4)])
    }

    @Test func aControlReachesTheRuntimeAndItsResponseIsKept() async throws {
      let scratch = try Scratch()
      let package = try makePackage(in: scratch.url)
      let app = try FakeApp(in: scratch.url)
      let simulator = FakeSimulator()
      simulator.state.withLock { $0.containers[bundle] = app.container }
      let responder = app.respond()
      defer { responder.cancel() }
      let receipt = scratch.url.appending(path: "receipt.json")
      let result = await run(
        [
          "--simulator", device, "--bundle", bundle, "--runtime-dir", package.path(),
          "--command-receipt", receipt.path(), "mute", call.uuidString, "--muted", "true",
        ], simulator: simulator)
      #expect(result.status == 0)
      let printed = try #require(result.output.first)
      let response = try JSONDecoder().decode(ControlResponse.self, from: Data(printed.utf8))
      guard case .success(.actions) = response.outcome else {
        Issue.record("Expected delivered actions")
        return
      }
      let kept = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
      let request = try #require(kept["request"] as? [String: Any])
      #expect(request["operation"] as? String == "mute" && request["muted"] as? Bool == true)
      #expect(request["callUUID"] as? String == call.uuidString)
      #expect((kept["session"] as? [String: Any])?["runID"] as? String == FakeApp.runID)
      let mode = try FileManager.default.attributesOfItem(atPath: receipt.path())[.posixPermissions]
      #expect((mode as? NSNumber)?.intValue == 0o600)
      #expect(
        await run(
          [
            "--simulator", device, "--bundle", bundle, "--runtime-dir", package.path(),
            "--command-receipt", receipt.path(), "status",
          ], simulator: simulator
        ).status == 1, "An existing receipt is never replaced")
    }

    @Test(arguments: ["id", "runID", "pid", "bundleID"])
    func aResponseForAnotherRequestIsRefused(field: String) async throws {
      let scratch = try Scratch()
      let app = try FakeApp(in: scratch.url)
      let responder = app.respond { _, response in
        response[field] = field == "pid" ? 99 : field == "id" ? UUID().uuidString : "other"
      }
      defer { responder.cancel() }
      let mailbox = Mailbox(
        target: Target(
          simctl: FakeSimulator().simctl, device: device, bundle: bundle,
          appContainer: app.container),
        timeout: .seconds(5))
      await #expect(throws: CKSimError("Runtime response identity mismatch.")) {
        try await mailbox.send(.status)
      }
    }

    @Test func anUnansweredControlHasAnUnknownOutcome() async throws {
      let scratch = try Scratch()
      let app = try FakeApp(in: scratch.url)
      let mailbox = Mailbox(
        target: Target(
          simctl: FakeSimulator().simctl, device: device, bundle: bundle,
          appContainer: app.container),
        timeout: .milliseconds(100))
      do {
        _ = try await mailbox.send(.status)
        Issue.record("The control didn't time out")
      } catch let error as CKSimError {
        #expect(
          error.description.hasSuffix(
            "timed out; outcome is unknown. Query status/events before retrying."))
      }
    }

    @Test(
      arguments: [
        ("bundleID", "dev.example.other" as any Sendable), ("pid", 0), ("pid", "12345"),
        ("runID", "../outside"), ("runID", ""),
      ] as [(String, any Sendable)])
    func anInvalidSessionIsRefused(key: String, value: any Sendable) async throws {
      let scratch = try Scratch()
      var session: [String: Any] = [
        "schemaVersion": 1, "bundleID": bundle, "pid": FakeApp.pid, "runID": FakeApp.runID,
        "profile": "ios-27.0", "controlTransport": "directory-watch-v1",
      ]
      session[key] = value
      let app = try FakeApp(in: scratch.url, session: session)
      let mailbox = Mailbox(
        target: Target(
          simctl: FakeSimulator().simctl, device: device, bundle: bundle,
          appContainer: app.container),
        timeout: .seconds(1))
      await #expect(
        throws: CKSimError("Invalid runtime session; launch the app with this runtime first.")
      ) {
        try await mailbox.send(.status)
      }
      #expect(
        try FileManager.default.contentsOfDirectory(
          atPath: app.mailbox.appending(path: "requests").path()
        ).isEmpty)
    }

    @Test func aCachedContainerMustBeTheSimulatorsDataContainer() throws {
      let scratch = try Scratch()
      let app = try FakeApp(in: scratch.url)
      let target = Target(
        simctl: FakeSimulator().simctl, device: device, bundle: bundle, appContainer: app.container)
      #expect(try target.container().pathComponents == app.container.pathComponents)
      for wrong in [scratch.url, app.container.appending(path: "Documents")] {
        let other = Target(
          simctl: target.simctl, device: device, bundle: bundle, appContainer: wrong)
        #expect(throws: CKSimError.self) { try other.container() }
      }
    }

    @Test func aPackageMustMatchItsManifest() throws {
      let scratch = try Scratch()
      let package = try makePackage(in: scratch.url)
      try RuntimePackage.validate(package)
      try Data("corrupted".utf8).write(to: package.appending(path: "CKSimRuntime.dylib"))
      #expect(throws: CKSimError("Runtime package checksum mismatch: CKSimRuntime.dylib")) {
        try RuntimePackage.validate(package)
      }

      let other = try makePackage(in: scratch.url.appending(path: "other"))
      let outside = other.deletingLastPathComponent().appending(path: "outside.dylib")
      try Data("outside".utf8).write(to: outside)
      let manifest = other.appending(path: "build-info.json")
      var info = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
      var files = try #require(info["files"] as? [String: String])
      files["../outside.dylib"] = sha256(try Data(contentsOf: outside))
      info["files"] = files
      try JSONSerialization.data(withJSONObject: info).write(to: manifest)
      #expect(throws: CKSimError("Runtime package checksum mismatch: ../outside.dylib")) {
        try RuntimePackage.validate(other)
      }
      #expect(RuntimePackage.isVersion("0.1.12") && !RuntimePackage.isVersion("01.1.0"))
      #expect(!RuntimePackage.isVersion("1.2") && !RuntimePackage.isVersion("1.2.x"))
    }

    @Test func launchInjectsThePackagesRuntime() async throws {
      let scratch = try Scratch()
      let package = try makePackage(in: scratch.url)
      let simulator = FakeSimulator()
      simulator.set("DYLD_INSERT_LIBRARIES", "/opt/other.dylib")
      let result = await run(
        ["--simulator", device, "--bundle", bundle, "--runtime-dir", package.path(), "launch"],
        simulator: simulator)
      #expect(result.status == 0)
      let environment = try #require(simulator.state.withLock { $0.launches.first })
      #expect(
        environment["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"]
          == "/opt/other.dylib:\(package.appending(path: "CKSimRuntime.dylib").path(percentEncoded: false))"
      )
      #expect(environment["SIMCTL_CHILD_CKSIM_ENABLED"] == "1")
      #expect(environment["SIMCTL_CHILD_CKSIM_PROFILE"] == "ios-27.0")

      simulator.set("CKSIM_RUNTIME", "/elsewhere/CKSimRuntime.dylib")
      #expect(
        await run(
          ["--simulator", device, "--bundle", bundle, "--runtime-dir", package.path(), "launch"],
          simulator: simulator
        ).status == 1, "Another release's runtime is selected")
    }
  }
#endif
