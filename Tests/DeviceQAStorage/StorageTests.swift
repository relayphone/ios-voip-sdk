import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private enum TestFailure: Error, CustomStringConvertible {
  case failed(String)
  var description: String { switch self { case .failed(let message): message } }
}

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw TestFailure.failed(message) }
}

private func temporary(_ test: (URL) throws -> Void) throws {
  let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("sdk-device-qa-tests-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: root) }
  try test(root)
}

private func mode(_ url: URL) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private func rejects(_ message: String, _ operation: () throws -> Void) throws {
  var rejected = false
  do { try operation() } catch { rejected = true }
  try expect(rejected, message)
}

private func root(_ documents: URL) -> URL { documents.appendingPathComponent("SDKDeviceQA") }
private func config(_ documents: URL) -> URL { root(documents).appendingPathComponent("config.json") }
private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }

private func childDirectory(_ parent: URL, _ name: String) throws -> URL {
  let url = parent.appendingPathComponent(name)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
  return url
}

@main
struct StorageTests {
  static func main() {
    do {
      var checks: [String] = []
      try privateDefaults(); checks.append("private-default-enrollment-paths-and-modes")
      try persistedConfiguration(); checks.append("persisted-run-config-and-separate-launch-traces")
      try records(); checks.append("utf8-json-lines-and-invalid-data-rejection")
      try tokens(); checks.append("stable-private-token-replacement-and-invalidation")
      try directorySymlinks(); checks.append("documents-and-private-directory-symlinks-rejected")
      try unsafeConfigurations(); checks.append("config-symlink-directory-fifo-and-hardlink-rejected")
      try unsafeTokens(); checks.append("token-symlink-and-hardlink-never-write-external-referents")
      try unsafeTraces(); checks.append("trace-symlink-hardlink-and-inode-replacement-rejected")
      try replacedDirectories(); checks.append("live-directory-replacement-rejects-later-writes")
      let encoded = try JSONSerialization.data(withJSONObject: ["success": true, "checks": checks], options: [.sortedKeys])
      print(String(decoding: encoded, as: UTF8.self))
    } catch {
      FileHandle.standardError.write(Data("Device QA storage check failed: \(error)\n".utf8))
      exit(1)
    }
  }

  private static func privateDefaults() throws {
    try temporary { documents in
      let storage = try SDKDeviceQAStorage(documentsURL: documents)
      try expect(try mode(root(documents)) == 0o700, "The QA directory must be private to its owner.")
      try expect(try mode(storage.traceURL.deletingLastPathComponent()) == 0o700, "The per-run directory must be private.")
      try expect(try mode(config(documents)) == 0o600 && mode(storage.traceURL) == 0o600,
                 "Configuration and each launch trace must use owner-only read/write permissions.")
      try expect(storage.configuration.scenario == .enrollment, "An absent configuration must start enrollment.")
      try expect(storage.traceURL.lastPathComponent == storage.launchID.uuidString + ".jsonl" &&
                 storage.traceURL.deletingLastPathComponent().lastPathComponent == storage.configuration.runID.uuidString,
                 "Every trace must be bound to its run and this launch.")
      try expect(!FileManager.default.fileExists(atPath: storage.tokenURL.path), "Enrollment must not invent a token file.")
    }
  }

  private static func persistedConfiguration() throws {
    try temporary { documents in
      let requested = SDKDeviceQAConfiguration(runID: UUID(), scenario: .coldReporting)
      let first = try SDKDeviceQAStorage(documentsURL: documents, configurationOverride: requested)
      try first.append(recordData: data(["event": "first-launch"]))
      let cold = try SDKDeviceQAStorage(documentsURL: documents)
      try expect(cold.configuration == requested && cold.launchID != first.launchID && cold.traceURL != first.traceURL,
                 "A cold launch must load the saved run while creating a distinct trace.")
      try expect(try Data(contentsOf: cold.traceURL).isEmpty && !Data(contentsOf: first.traceURL).isEmpty,
                 "A new launch must never mix its trace with an earlier process.")
      try expect(cold.tokenURL == first.tokenURL && cold.tokenURL.deletingLastPathComponent() == root(documents),
                 "The current token has a stable path outside the per-launch traces.")
      for scenario in [SDKDeviceQAConfiguration.Scenario.enrollment, .lockedAnswer, .activeCall, .coldReporting] {
        let override = SDKDeviceQAConfiguration(runID: UUID(), scenario: scenario)
        let configured = try SDKDeviceQAStorage(documentsURL: documents, configurationOverride: override)
        let persisted = try JSONDecoder().decode(SDKDeviceQAConfiguration.self, from: Data(contentsOf: config(documents)))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: config(documents))) as? [String: Any]
        try expect(configured.configuration == override && persisted == override && object?["scenario"] as? String == scenario.rawValue,
                   "Overrides must atomically persist the exact requested run and wire scenario.")
      }
      try expect(try !FileManager.default.contentsOfDirectory(atPath: root(documents).path).contains { $0.hasSuffix(".tmp") },
                 "Atomic configuration updates must not leave temporary files.")
    }
  }

  private static func records() throws {
    try temporary { documents in
      let storage = try SDKDeviceQAStorage(documentsURL: documents)
      let first = try data(["event": "one", "text": "zażółć\nsecond line"])
      let second = try data(["event": "two", "padding": String(repeating: "x", count: 9_000)])
      try storage.append(recordData: first)
      try storage.append(recordData: second)
      try storage.append(recordData: Data("null".utf8))
      let before = try Data(contentsOf: storage.traceURL)
      let lines = before.split(separator: 0x0a, omittingEmptySubsequences: true)
      try expect(lines.count == 3 && before.last == 0x0a && Data(lines[0]) == first && Data(lines[1]) == second && Data(lines[2]) == Data("null".utf8),
                 "Each valid UTF-8 JSON value must append once, byte-for-byte, with a single trailing newline.")
      for invalid in [Data(), Data("not JSON".utf8), Data("{}\n{}".utf8), Data("{}\r".utf8), Data([0xff, 0xfe])] {
        try rejects("Invalid or multiline data must not enter a JSONL trace.") { try storage.append(recordData: invalid) }
      }
      try expect(try Data(contentsOf: storage.traceURL) == before, "Rejected records must leave prior evidence unchanged.")
    }
  }

  private static func tokens() throws {
    try temporary { documents in
      let storage = try SDKDeviceQAStorage(documentsURL: documents)
      let fixture = "synthetic-token-for-storage-test"
      try storage.writeToken(fixture)
      try expect(try mode(storage.tokenURL) == 0o600 && String(contentsOf: storage.tokenURL, encoding: .utf8) == fixture,
                 "Token bytes must be stored only in an owner-readable current-token file.")
      try storage.append(recordData: data(["event": "token-updated"]))
      try expect(try !Data(contentsOf: storage.traceURL).contains(Data(fixture.utf8)), "The storage helper must not copy token values into traces.")
      try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: storage.tokenURL.path)
      let next = try SDKDeviceQAStorage(documentsURL: documents)
      try expect(try next.tokenURL == storage.tokenURL && mode(next.tokenURL) == 0o600,
                 "Cold launches must retain the stable current-token location and enforce its private permissions.")
      try next.writeToken("replacement-fixture")
      try expect(try String(contentsOf: storage.tokenURL, encoding: .utf8) == "replacement-fixture" && mode(storage.tokenURL) == 0o600,
                 "Replacing the current token must retain private permissions.")
      try next.writeToken(nil)
      try next.writeToken(nil)
      try expect(!FileManager.default.fileExists(atPath: storage.tokenURL.path), "Token invalidation must remove the current token and remain idempotent.")
    }
  }

  private static func directorySymlinks() throws {
    try temporary { parent in
      let documents = try childDirectory(parent, "documents")
      let outside = try childDirectory(parent, "outside")
      let sentinel = outside.appendingPathComponent("config.json")
      let original = Data("outside sentinel".utf8)
      try original.write(to: sentinel)
      let alias = parent.appendingPathComponent("documents-link")
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: documents)
      try rejects("The supplied Documents directory must not itself be a symlink.") { _ = try SDKDeviceQAStorage(documentsURL: alias) }
      try FileManager.default.createSymbolicLink(at: root(documents), withDestinationURL: outside)
      try rejects("The private QA directory must never follow a symlink.") { _ = try SDKDeviceQAStorage(documentsURL: documents) }
      try expect(try Data(contentsOf: sentinel) == original && FileManager.default.contentsOfDirectory(atPath: outside.path) == ["config.json"],
                 "Rejected directories must leave external contents untouched.")
    }
  }

  private static func unsafeConfigurations() throws {
    for kind in ["symlink", "directory", "fifo", "hardlink"] {
      try temporary { parent in
        let documents = try childDirectory(parent, "documents")
        _ = try childDirectory(documents, "SDKDeviceQA")
        let outside = parent.appendingPathComponent("outside-config")
        let original = Data("outside sentinel".utf8)
        try original.write(to: outside)
        switch kind {
        case "symlink": try FileManager.default.createSymbolicLink(at: config(documents), withDestinationURL: outside)
        case "directory": _ = try childDirectory(root(documents), "config.json")
        case "fifo": try expect(mkfifo(config(documents).path, 0o600) == 0, "The FIFO fixture must be created.")
        default: try FileManager.default.linkItem(at: outside, to: config(documents))
        }
        try rejects("An unsafe config path must reject cold-launch reads.") { _ = try SDKDeviceQAStorage(documentsURL: documents) }
        try rejects("Overrides must not replace an unsafe config path.") {
          _ = try SDKDeviceQAStorage(documentsURL: documents, configurationOverride: .init(runID: UUID(), scenario: .activeCall))
        }
        try expect(try Data(contentsOf: outside) == original, "Config refusal must never alter an external referent.")
      }
    }
  }

  private static func unsafeTokens() throws {
    for hardlink in [false, true] {
      try temporary { parent in
        let documents = try childDirectory(parent, "documents")
        let storage = try SDKDeviceQAStorage(documentsURL: documents)
        let outside = parent.appendingPathComponent("outside-token")
        let original = Data("outside sentinel".utf8)
        try original.write(to: outside)
        if hardlink { try FileManager.default.linkItem(at: outside, to: storage.tokenURL) }
        else { try FileManager.default.createSymbolicLink(at: storage.tokenURL, withDestinationURL: outside) }
        try rejects("An unsafe token path must reject writes.") { try storage.writeToken("replacement-fixture") }
        try rejects("Token invalidation must reject an unsafe owned path.") { try storage.writeToken(nil) }
        try rejects("A cold launch must reject an unsafe existing token path.") { _ = try SDKDeviceQAStorage(documentsURL: documents) }
        try expect(try Data(contentsOf: outside) == original, "Token operations must not change external referent bytes.")
      }
    }
  }

  private static func unsafeTraces() throws {
    for kind in ["symlink", "hardlink", "replacement"] {
      try temporary { parent in
        let documents = try childDirectory(parent, "documents")
        let storage = try SDKDeviceQAStorage(documentsURL: documents)
        let outside = parent.appendingPathComponent("outside-trace")
        let original = Data("outside sentinel".utf8)
        try original.write(to: outside)
        try FileManager.default.removeItem(at: storage.traceURL)
        switch kind {
        case "symlink": try FileManager.default.createSymbolicLink(at: storage.traceURL, withDestinationURL: outside)
        case "hardlink": try FileManager.default.linkItem(at: outside, to: storage.traceURL)
        default: try Data("replacement".utf8).write(to: storage.traceURL)
        }
        try rejects("A substituted trace path must be rejected before appending.") { try storage.append(recordData: data(["event": "unsafe"])) }
        try expect(try Data(contentsOf: outside) == original, "Rejected traces must not append to an external referent.")
      }
    }
  }

  private static func replacedDirectories() throws {
    for replacesRoot in [false, true] {
      try temporary { parent in
        let documents = try childDirectory(parent, "documents")
        let storage = try SDKDeviceQAStorage(documentsURL: documents)
        let outside = try childDirectory(parent, "outside")
        let originalDirectory = replacesRoot ? root(documents) : storage.traceURL.deletingLastPathComponent()
        let retired = parent.appendingPathComponent("retired")
        try FileManager.default.moveItem(at: originalDirectory, to: retired)
        try FileManager.default.createSymbolicLink(at: originalDirectory, withDestinationURL: outside)
        try rejects("Replacing a live private directory must reject later trace writes.") { try storage.append(recordData: data(["event": "unsafe"])) }
        try rejects("Replacing a live private directory must reject later token writes.") { try storage.writeToken("replacement-fixture") }
        try rejects("New launches must reject the substituted private directory.") { _ = try SDKDeviceQAStorage(documentsURL: documents) }
        try expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty,
                   "No external file may be created through a replaced directory.")
      }
    }
  }
}
