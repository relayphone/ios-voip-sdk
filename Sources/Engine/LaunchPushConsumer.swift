#if os(macOS) || (os(iOS) && targetEnvironment(simulator))
  import CryptoKit
  import Darwin
  import Foundation
  #if SWIFT_PACKAGE
    import CKSimProtocol
  #endif

  /// Claims a staged push exactly once before validating its content for this process.
  enum LaunchPushConsumer {
    struct Consumed {
      let envelope: PushLaunchEnvelope
      let sha256: String
    }

    enum Failure: Error, CustomStringConvertible {
      case unsafeEnvelope, claimFailed, invalidEnvelope
      var description: String {
        switch self {
        case .unsafeEnvelope: "unsafe launch envelope"
        case .claimFailed: "cannot claim launch envelope"
        case .invalidEnvelope: "invalid or expired launch envelope"
        }
      }
    }

    static func consume(
      directory: URL, runID: String, bundleID: String, nowMS: Int64, owner: uid_t
    ) throws -> Consumed? {
      let file = directory.appending(path: "push-launch.json")
      var source = stat()
      guard lstat(file.path, &source) == 0 else {
        if errno == ENOENT { return nil }
        throw Failure.unsafeEnvelope
      }
      var folder = stat()
      guard lstat(directory.path, &folder) == 0, folder.st_mode & S_IFMT == S_IFDIR,
        folder.st_uid == owner, folder.st_mode & 0o7777 == 0o700,
        source.st_mode & S_IFMT == S_IFREG, source.st_uid == owner,
        source.st_mode & 0o7777 == 0o600, source.st_nlink == 1,
        source.st_size > 0, source.st_size <= 8192
      else { throw Failure.unsafeEnvelope }
      let claimed = directory.appending(path: "push-launch.consuming")
      guard renamex_np(file.path, claimed.path, UInt32(RENAME_EXCL)) == 0 else {
        throw Failure.claimFailed
      }
      defer { unlink(claimed.path) }
      let descriptor = open(claimed.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      guard descriptor >= 0 else { throw Failure.unsafeEnvelope }
      defer { close(descriptor) }
      var actual = stat()
      guard fstat(descriptor, &actual) == 0, actual.st_dev == source.st_dev,
        actual.st_ino == source.st_ino, actual.st_mode & S_IFMT == S_IFREG,
        actual.st_size == source.st_size, actual.st_uid == owner,
        actual.st_mode & 0o7777 == 0o600, actual.st_nlink == 1
      else { throw Failure.unsafeEnvelope }
      var bytes = Data(count: Int(actual.st_size))
      let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
      guard count == bytes.count else { throw Failure.unsafeEnvelope }
      do {
        let envelope = try JSONDecoder().decode(PushLaunchEnvelope.self, from: bytes)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          object["id"] as? String == envelope.id.uuidString
        else { throw Failure.invalidEnvelope }
        try envelope.validate(runID: runID, bundleID: bundleID, nowMS: nowMS)
        return Consumed(
          envelope: envelope,
          sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
      } catch { throw Failure.invalidEnvelope }
    }
  }
#endif

#if os(iOS) && targetEnvironment(simulator)
  // Retains the existing C boundary used by the PushKit delivery hook.
  @_cdecl("CKSimConsumeLaunchPush")
  func consumeLaunchPush(
    _ directory: NSString, _ runID: NSString, _ bundleID: NSString, _ now: Double,
    _ owner: uid_t, _ reason: AutoreleasingUnsafeMutablePointer<NSString?>?
  ) -> NSDictionary? {
    reason?.pointee = nil
    guard now.isFinite, now >= 0, now * 1000 < Double(Int64.max) else {
      reason?.pointee = "invalid or expired launch envelope"
      return nil
    }
    do {
      guard
        let consumed = try LaunchPushConsumer.consume(
          directory: URL(filePath: directory as String), runID: runID as String,
          bundleID: bundleID as String, nowMS: Int64(now * 1000), owner: owner)
      else { return nil }
      let bytes = try JSONEncoder().encode(consumed.envelope)
      guard var object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
        throw LaunchPushConsumer.Failure.invalidEnvelope
      }
      object["envelopeSHA256"] = consumed.sha256
      return object as NSDictionary
    } catch {
      reason?.pointee = String(describing: error) as NSString
      return nil
    }
  }
#endif
