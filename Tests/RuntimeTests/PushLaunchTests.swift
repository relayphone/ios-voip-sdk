#if os(iOS) && targetEnvironment(simulator)
  import CKSimRuntimeC
  import Darwin
  import Foundation
  import Testing

  /// The runtime's consumption of a VoIP push that `cksim push --launch` staged for the app's
  /// next launch.
  @Suite(.serialized)
  struct PushLaunch {
    private static var envelope: [String: Any] {
      [
        "schemaVersion": 1, "id": "AC163EA0-9825-42B9-91B2-93075FCE8A63", "runID": "launch-test",
        "bundleID": "dev.example", "createdAtMS": 100_000, "expiresAtMS": 120_000,
        "mustReport": true, "payload": ["incomingCall": [String: Any]()],
      ]
    }

    private let directory: URL
    private var file: URL { directory.appending(path: "push-launch.json") }

    init() throws {
      directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    }

    private func stage(_ envelope: [String: Any] = Self.envelope) throws {
      try? FileManager.default.removeItem(at: file)
      #expect(
        FileManager.default.createFile(
          atPath: file.path(), contents: try JSONSerialization.data(withJSONObject: envelope),
          attributes: [.posixPermissions: 0o600]))
    }

    /// Consumes the staged push at 110 seconds past the epoch.
    private func consume(owner: uid_t = getuid()) -> (delivered: Bool, reason: String?) {
      var reason: NSString?
      let push = CKSimConsumeLaunchPush(
        directory.path(), "launch-test", "dev.example", 110, owner, &reason)
      return (push != nil, reason as String?)
    }

    @Test func aStagedPushIsDeliveredOnce() throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      try stage()
      #expect(consume().delivered)
      let replay = consume()
      #expect(!replay.delivered && replay.reason == nil, "Nothing is left to deliver")
    }

    @Test(
      arguments: [
        ("runID", "wrong"), ("bundleID", "wrong"), ("id", "wrong"), ("expiresAtMS", 109_000),
        ("createdAtMS", 200_000), ("mustReport", 1),
      ] as [(String, any Sendable)])
    func anEnvelopeForAnotherLaunchIsRefusedAndRemoved(key: String, value: any Sendable) throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      var envelope = Self.envelope
      envelope[key] = value
      try stage(envelope)
      let result = consume()
      #expect(!result.delivered && result.reason != nil)
      #expect(!FileManager.default.fileExists(atPath: file.path()))
    }

    @Test func anUnsafeFileOrDirectoryIsRefused() throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      try stage()
      #expect(chmod(file.path(), 0o644) == 0)
      #expect(!consume().delivered, "A file others can read")
      try stage()
      #expect(!consume(owner: getuid() + 1).delivered, "Another user's file")
      try stage()
      #expect(chmod(directory.path(), 0o755) == 0)
      #expect(!consume().delivered, "A directory others can read")
      #expect(chmod(directory.path(), 0o700) == 0)
      try FileManager.default.removeItem(at: file)
      #expect(symlink("/etc/hosts", file.path()) == 0)
      #expect(!consume().delivered, "A symbolic link")
    }

    @Test func anExistingClaimIsLeftAlone() throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      try stage()
      let claim = directory.appending(path: "push-launch.consuming")
      try Data("existing claim".utf8).write(to: claim)
      #expect(!consume().delivered)
      #expect(try String(contentsOf: claim, encoding: .utf8) == "existing claim")
    }
  }
#endif
