#if os(macOS)
  import Foundation
  import Testing

  @testable import CKSimTool

  /// `cksim push --launch`: staging a push for a stopped app.
  struct PushLaunchTests {
    private let scratch: Scratch
    private let app: FakeApp
    private let launch: PushLaunch

    init() throws {
      scratch = try Scratch()
      app = try FakeApp(in: scratch.url)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: app.channel.path())
      let payload = scratch.url.appending(path: "payload.json")
      try Data(#"{"aps":{},"callId":"launch-1"}"#.utf8).write(to: payload)
      launch = PushLaunch(
        target: Target(simctl: FakeSimulator().simctl, device: device, bundle: bundle),
        runID: "launch-run", mustReport: true, payloadFile: payload,
        receipt: scratch.url.appending(path: "launch-receipt.json"))
    }

    private static let stopped = Data(
      "PID\tStatus\tLabel\n-\t0\tUIKitApplication:\(bundle)[1a2b]\n".utf8)

    @Test func aStagedPushHasItsEnvelopeAndReceipt() throws {
      let before = Int(Date().timeIntervalSince1970 * 1000)
      let (arguments, environment) = try launch.stage(
        container: app.container, serviceTable: Self.stopped)
      #expect(arguments == ["/usr/bin/xcrun", "simctl", "launch", "--console", device, bundle])
      #expect(environment["SIMCTL_CHILD_CKSIM_RUN_ID"] == "launch-run")
      #expect(environment["SIMCTL_CHILD_CKSIM_ENABLED"] == nil)
      let file = app.channel.appending(path: "push-launch.json")
      let data = try Data(contentsOf: file)
      let envelope = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(
        Set(envelope.keys) == [
          "schemaVersion", "id", "runID", "bundleID", "createdAtMS", "expiresAtMS", "mustReport",
          "payload",
        ])
      let created = try #require(envelope["createdAtMS"] as? Int)
      #expect(created >= before && envelope["expiresAtMS"] as? Int == created + 30_000)
      #expect(
        envelope["runID"] as? String == "launch-run" && envelope["mustReport"] as? Bool == true)
      let mode = try FileManager.default.attributesOfItem(atPath: file.path())[.posixPermissions]
      #expect((mode as? NSNumber)?.intValue == 0o600)
      let receipt = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: launch.receipt)) as? [String: Any])
      #expect(receipt["envelopeSHA256"] as? String == sha256(data))
      #expect(receipt["pushID"] as? String == envelope["id"] as? String)
      #expect(receipt["appServiceAbsent"] as? Bool == true && receipt["mode"] as? Int == 0o600)
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: app.channel.path()).allSatisfy {
          !$0.hasPrefix(".push-launch-")
        })
      #expect(throws: CKSimError.self, "A pending push is never replaced") {
        try PushLaunch(
          target: launch.target, runID: "launch-run", mustReport: true,
          payloadFile: launch.payloadFile, receipt: scratch.url.appending(path: "second.json")
        ).stage(container: app.container, serviceTable: Self.stopped)
      }
    }

    @Test(arguments: [
      ("", "Invalid launchctl service table"),
      ("PID\tStatus\tLabel\n", "Invalid launchctl service table"),
      ("PID\tStatus\tLabel\ninvalid\t0\tlabel\n", "Invalid launchctl service table"),
      ("PID\tStatus\tLabel\n812\t0\tUIKitApplication:\(bundle)[1a2b]\n", "requires a stopped app"),
    ])
    func aRunningAppOrAnUnreadableTableIsRefused(table: String, message: String) throws {
      do {
        _ = try launch.stage(container: app.container, serviceTable: Data(table.utf8))
        Issue.record("The push was staged")
      } catch let error as CKSimError {
        #expect(error.description.contains(message))
      }
      #expect(!FileManager.default.fileExists(atPath: launch.receipt.path()))
    }

    @Test func anUnsafeDirectoryIsRefused() throws {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: app.channel.path())
      #expect(throws: CKSimError("Unsafe push launch directory.")) {
        try launch.stage(container: app.container, serviceTable: Self.stopped)
      }
    }
  }
#endif
