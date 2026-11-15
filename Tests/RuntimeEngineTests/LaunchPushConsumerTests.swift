#if os(macOS)
  import CryptoKit
  import Darwin
  import Foundation
  import Testing
  import CKSimProtocol
  @testable import CKSimRuntime

  struct LaunchPushConsumerTests {
    let directory: URL
    let envelope: PushLaunchEnvelope
    var file: URL { directory.appending(path: "push-launch.json") }

    init() throws {
      directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      envelope = try PushLaunchEnvelope(
        version: .singleDelivery, id: UUID(), runID: "cold-run", bundleID: "dev.example",
        createdAtMS: 100_000, expiresAtMS: 120_000, mustReport: true,
        payload: PushPayload(fields: ["callId": .string("one")]))
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func stage(_ value: PushLaunchEnvelope? = nil) throws -> Data {
      let bytes = try JSONEncoder().encode(value ?? envelope)
      #expect(
        FileManager.default.createFile(
          atPath: file.path, contents: bytes, attributes: [.posixPermissions: 0o600]))
      return bytes
    }

    func consume(run: String = "cold-run", now: Int64 = 110_000, owner: uid_t = getuid()) throws
      -> LaunchPushConsumer.Consumed?
    {
      try LaunchPushConsumer.consume(
        directory: directory, runID: run, bundleID: "dev.example", nowMS: now, owner: owner)
    }

    @Test func claimsOnceAndHashesExactlyTheClaimedBytes() throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      var bytes = try JSONEncoder().encode(envelope)
      bytes.append(10)
      #expect(
        FileManager.default.createFile(
          atPath: file.path, contents: bytes, attributes: [.posixPermissions: 0o600]))
      let value = try #require(try consume())
      #expect(value.envelope == envelope)
      #expect(value.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
      #expect(try consume() == nil)
      #expect(
        !FileManager.default.fileExists(
          atPath: directory.appending(path: "push-launch.consuming").path))
    }

    @Test func deliveryPlansRetainTheirStableIdentities() throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      let plan = try PushLaunchEnvelope(
        id: envelope.id, runID: envelope.runID, bundleID: envelope.bundleID,
        createdAtMS: envelope.createdAtMS, expiresAtMS: envelope.expiresAtMS,
        mustReport: true, payload: envelope.payload,
        delivery: PushDeliveryFaults(duplicate: 2, spacingMS: 500),
        deliveryIDs: [envelope.id, UUID(), UUID()])
      _ = try stage(plan)
      #expect(try consume()?.envelope == plan)
    }

    @Test(arguments: ["expired", "wrong-run", "future", "malformed"])
    func invalidClaimIsRemovedWithoutDelivery(kind: String) throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      if kind == "malformed" {
        #expect(
          FileManager.default.createFile(
            atPath: file.path, contents: Data("not-json".utf8),
            attributes: [.posixPermissions: 0o600]))
      } else {
        _ = try stage()
      }
      #expect(throws: (any Error).self) {
        try consume(
          run: kind == "wrong-run" ? "another-run" : "cold-run",
          now: kind == "expired" ? 120_000 : kind == "future" ? 98_999 : 110_000)
      }
      #expect(!FileManager.default.fileExists(atPath: file.path))
      #expect(try consume() == nil)
    }

    @Test(arguments: ["mode", "directory-mode", "owner", "symlink", "hardlink", "fifo", "oversize"])
    func unsafeFilesAreRejectedBeforeClaim(kind: String) throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      _ = try stage()
      switch kind {
      case "mode": #expect(chmod(file.path, 0o644) == 0)
      case "directory-mode": #expect(chmod(directory.path, 0o755) == 0)
      case "symlink":
        #expect(unlink(file.path) == 0)
        #expect(symlink("/etc/hosts", file.path) == 0)
      case "hardlink": #expect(link(file.path, directory.appending(path: "copy").path) == 0)
      case "fifo":
        #expect(unlink(file.path) == 0)
        #expect(mkfifo(file.path, 0o600) == 0)
      case "oversize": try Data(repeating: 32, count: 8193).write(to: file)
      default: break
      }
      #expect(throws: (any Error).self) {
        try consume(owner: kind == "owner" ? getuid() + 1 : getuid())
      }
      var status = stat()
      #expect(lstat(file.path, &status) == 0)
    }

    @Test func existingClaimIsNeverOverwritten() throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      _ = try stage()
      let claim = directory.appending(path: "push-launch.consuming")
      let bytes = Data("another consumer".utf8)
      try bytes.write(to: claim)
      #expect(throws: (any Error).self) { try consume() }
      #expect(try Data(contentsOf: claim) == bytes)
      #expect(FileManager.default.fileExists(atPath: file.path))
    }
  }
#endif
