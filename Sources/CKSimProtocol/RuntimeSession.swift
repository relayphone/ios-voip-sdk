import Foundation

/// The identity and mailbox transport published by a simulator runtime.
public struct RuntimeSession: Codable, Equatable, Sendable {
  /// The supported runtime session wire version.
  public let schemaVersion: Int
  /// The application that owns the runtime mailbox.
  public let bundleID: String
  /// The identifier of one runtime invocation.
  public let runID: String
  /// The process that owns the runtime mailbox.
  public let pid: Int
  /// The behavior profile loaded by the runtime.
  public let profile: String
  /// The transport used to publish controls to this runtime.
  public let controlTransport: ControlTransport

  /// A supported runtime mailbox transport.
  public enum ControlTransport: String, Codable, Sendable {
    /// Atomic request files observed by the runtime's directory watcher.
    case directoryWatchV1 = "directory-watch-v1"
  }

  /// A session identity that cannot safely name a runtime mailbox.
  public enum ValidationError: Error, Equatable, Sendable {
    /// Run identifiers require 1–64 ASCII letters, digits, underscores or hyphens.
    case invalidRunID
    /// The runtime must belong to a positive process identifier.
    case invalidProcessID
    /// The runtime must name its owning application.
    case emptyBundleID
    /// The runtime must name its behavior profile.
    case emptyProfile
  }

  /// Creates a version-one session with validated mailbox identity.
  ///
  /// - Throws: ``ValidationError`` if any identity field is invalid.
  public init(
    bundleID: String, runID: String, pid: Int, profile: String,
    controlTransport: ControlTransport = .directoryWatchV1
  ) throws(ValidationError) {
    guard validRuntimeRunID(runID)
    else { throw .invalidRunID }
    guard pid > 0 else { throw .invalidProcessID }
    guard !bundleID.isEmpty else { throw .emptyBundleID }
    guard !profile.isEmpty else { throw .emptyProfile }
    schemaVersion = 1
    self.bundleID = bundleID
    self.runID = runID
    self.pid = pid
    self.profile = profile
    self.controlTransport = controlTransport
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, bundleID, runID, pid, profile, controlTransport
  }

  /// Decodes a supported session without defaulting absent identity or transport.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    guard try values.decode(Int.self, forKey: .schemaVersion) == 1 else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion, in: values, debugDescription: "Unsupported runtime session schema"
      )
    }
    try self.init(
      bundleID: values.decode(String.self, forKey: .bundleID),
      runID: values.decode(String.self, forKey: .runID),
      pid: values.decode(Int.self, forKey: .pid),
      profile: values.decode(String.self, forKey: .profile),
      controlTransport: values.decode(ControlTransport.self, forKey: .controlTransport)
    )
  }
}
