import Foundation

/// The application process and runtime invocation addressed by a mailbox request.
public struct RuntimeIdentity: Codable, Equatable, Sendable {
  /// The owning application's bundle identifier.
  public let bundleID: String
  /// The runtime invocation identifier.
  public let runID: String
  /// The owning process identifier.
  public let pid: Int

  /// An identity that cannot safely address a runtime mailbox.
  public enum ValidationError: Error, Equatable, Sendable {
    /// The run identifier is outside the supported ASCII mailbox format.
    case invalidRunID
    /// Process identifiers must be positive.
    case invalidProcessID
    /// An owning application must be named.
    case emptyBundleID
  }

  /// Creates a validated address without requiring unrelated session metadata.
  public init(bundleID: String, runID: String, pid: Int) throws(ValidationError) {
    guard validRuntimeRunID(runID) else { throw .invalidRunID }
    guard pid > 0 else { throw .invalidProcessID }
    guard !bundleID.isEmpty else { throw .emptyBundleID }
    self.bundleID = bundleID
    self.runID = runID
    self.pid = pid
  }

  private enum CodingKeys: String, CodingKey { case bundleID, runID, pid }

  /// Decodes the existing flat identity fields, requiring every scalar.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      bundleID: values.decode(String.self, forKey: .bundleID),
      runID: values.decode(String.self, forKey: .runID),
      pid: values.decode(Int.self, forKey: .pid))
  }
}

func validRuntimeRunID(_ value: String) -> Bool {
  (1...64).contains(value.utf8.count)
    && value.utf8.allSatisfy {
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
        || $0 == 95
    }
}
