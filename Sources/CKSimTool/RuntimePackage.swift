#if os(macOS)
  import CryptoKit
  import Foundation

  /// A standalone runtime package, as `tools/build-runtime.ts` makes it: the runtime, its loader,
  /// `cksim`, the behaviour profile and `build-info.json`, a manifest of every file's digest.
  enum RuntimePackage {
    static let required: Set = [
      "CKSimRuntime.dylib", "CKSimLoader.dylib", "cksim", "profiles/ios-27.0.json", "VERSION",
    ]

    private struct BuildInfo: Decodable {
      let schemaVersion: Int
      let version: String
      let files: [String: String]
    }

    /// Checks that the package is complete and that every file matches its recorded digest.
    static func validate(_ directory: URL) throws {
      let root = directory.standardizedFileURL.resolvingSymlinksInPath()
      guard
        let info = try? JSONDecoder().decode(
          BuildInfo.self, from: Data(contentsOf: root.appending(path: "build-info.json"))),
        let version = try? String(contentsOf: root.appending(path: "VERSION"), encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines),
        info.schemaVersion == 1, isVersion(version), info.version == version,
        required.isSubset(of: info.files.keys)
      else { throw CKSimError("Incomplete or unsupported runtime package.") }
      for (name, digest) in info.files.sorted(by: { $0.key < $1.key }) {
        let file = root.appending(path: name).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path().hasPrefix(root.path() + (root.path().hasSuffix("/") ? "" : "/")),
          let data = try? Data(contentsOf: file), sha256(data) == digest
        else { throw CKSimError("Runtime package checksum mismatch: \(name)") }
      }
    }

    /// Whether the text is a version of the form `1.2.3`, without leading zeros.
    static func isVersion(_ text: String) -> Bool {
      let parts = text.split(separator: ".", omittingEmptySubsequences: false)
      return parts.count == 3
        && parts.allSatisfy { part in
          !part.isEmpty && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber)
            && (part == "0" || !part.hasPrefix("0"))
        }
    }
  }

  func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
#endif
