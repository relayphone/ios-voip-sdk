"""Exercise private phase receipts; UIKit state itself needs the native probe."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
BUNDLE = 'dev.callkitsim.foreground-phase-host-test'
HARNESS = r'''
import Foundation
@main @MainActor struct PhaseProbeTest {
  static func main() throws {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let identityURL = documents.appendingPathComponent("cksim-foreground-phase-identity.json")
    let requestURL = documents.appendingPathComponent("cksim-foreground-phase-request.json")
    let ackURL = documents.appendingPathComponent("cksim-foreground-phase-ack.json")
    let probe = ForegroundPhaseProbe(nonce: "fixture-host-test", startedWallTimeMS: 1234)!
    let session = ForegroundPhaseSession(schemaVersion: 1, bundleID: "dev.callkitsim.target",
      runID: "fixture-host-test", pid: 2468, profile: "ios-27.0")
    func sample(_ state: ForegroundPhaseProbe.TestApplicationState) { probe.sample(session: session, applicationState: state) }
    func read(_ path: URL) throws -> [String: Any] {
      try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
    }
    func write(_ value: [String: Any]) throws {
      try JSONSerialization.data(withJSONObject: value).write(to: requestURL, options: .atomic)
    }
    func requireData(_ path: URL, _ expected: Data, _ message: String) throws {
      let actual = try Data(contentsOf: path)
      precondition(actual == expected, message)
    }
    sample(.background)
    let identityData = try Data(contentsOf: identityURL)
    let identity = try read(identityURL)
    var request = identity
    request["phase"] = "fixture-before-incoming"
    request["challenge"] = UUID().uuidString
    try write(request)
    sample(.background)
    precondition(!FileManager.default.fileExists(atPath: ackURL.path), "background published ACTIVE")
    sample(.inactive)
    precondition(!FileManager.default.fileExists(atPath: ackURL.path), "inactive published ACTIVE")
    sample(.active)
    let first = try read(ackURL)
    let firstData = try Data(contentsOf: ackURL)
    for field in ["schemaVersion", "phase", "challenge", "nonce", "pid", "bundleID", "dataContainer", "startedWallTimeMS", "session"] {
      var foreign = request
      if field == "session" { foreign[field] = ["schemaVersion": 1, "bundleID": "foreign", "runID": "foreign", "pid": 22, "profile": "ios-27.0"] }
      else if field == "pid" || field == "schemaVersion" || field == "startedWallTimeMS" { foreign[field] = -1 }
      else if field == "phase" { foreign[field] = "invalid/phase" }
      else { foreign[field] = "foreign" }
      try write(foreign)
      sample(.active)
      try requireData(ackURL, firstData, "foreign field accepted: \(field)")
    }
    for invalid in [Data("{".utf8), Data(repeating: 32, count: 16385)] {
      try invalid.write(to: requestURL, options: .atomic)
      sample(.active)
      try requireData(ackURL, firstData, "malformed request accepted")
    }
    request["challenge"] = UUID().uuidString
    request["phase"] = "inspector-after-reap"
    try write(request)
    sample(.background)
    try requireData(ackURL, firstData, "background answered fresh challenge")
    sample(.active)
    let second = try read(ackURL)
    sample(.active)
    let third = try read(ackURL)
    precondition(first["challenge"] as? String != second["challenge"] as? String)
    precondition(second["challenge"] as? String == third["challenge"] as? String)
    precondition(second["publicationID"] as? String != third["publicationID"] as? String)
    try requireData(identityURL, identityData, "native startup identity changed")
    let pinned = try Data(contentsOf: ackURL)
    let changed = ForegroundPhaseSession(schemaVersion: 1, bundleID: session.bundleID,
      runID: "new-run", pid: session.pid, profile: session.profile)
    probe.sample(session: changed, applicationState: .active)
    try requireData(ackURL, pinned, "changed session accepted")
    let output: [String: Any] = ["identity": identity, "first": first, "second": second, "third": third]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output))
  }
}
'''


class ForegroundPhaseProbeTests(unittest.TestCase):
    def test_phase_challenge_requires_active_and_pinned_native_identity(self):
        source = ROOT / 'Inspector/ForegroundPhaseProbe.swift'
        self.assertTrue(source.is_file(), 'native foreground phase probe is missing')
        with tempfile.TemporaryDirectory(prefix='foreground-phase-probe-') as directory:
            work = Path(directory)
            lines = source.read_text().splitlines()
            self.assertEqual((lines[0], lines[-1]), ('#if targetEnvironment(simulator)', '#endif'))
            model, harness = work / 'ForegroundPhaseProbe.swift', work / 'Main.swift'
            model.write_text('\n'.join(lines[1:-1]) + '\n')
            harness.write_text(HARNESS)
            contents = work / 'PhaseProbe.app' / 'Contents'
            binary = contents / 'MacOS' / 'PhaseProbe'
            binary.parent.mkdir(parents=True)
            with (contents / 'Info.plist').open('wb') as output:
                plistlib.dump(dict(CFBundleIdentifier=BUNDLE, CFBundleExecutable=binary.name,
                                   CFBundlePackageType='APPL'), output)
            built = subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library',
                '-module-cache-path', str(work / 'module-cache'), str(model), str(harness),
                '-o', str(binary)], text=True, capture_output=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            container, home = work / 'canonical-container', work / 'home'
            documents = container / 'Documents'
            documents.mkdir(parents=True)
            home.mkdir()
            (home / 'Documents').symlink_to(documents, target_is_directory=True)
            environment = dict(os.environ, CFFIXED_USER_HOME=str(home),
                               PHASE_SECRET_CANARY='must-not-appear', CKSIM_INSPECTOR_TOKEN='secret-token')
            result = subprocess.run([str(binary)], env=environment, text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            value = json.loads(result.stdout)
            identity = value['identity']
            self.assertEqual(identity['bundleID'], BUNDLE)
            self.assertEqual(identity['dataContainer'], str(container.resolve()))
            self.assertGreater(identity['pid'], 0)
            self.assertEqual(identity['startedWallTimeMS'], 1234)
            self.assertEqual(identity['nonce'], 'fixture-host-test')
            for key in ('first', 'second', 'third'):
                ack = value[key]
                for field, expected in identity.items():
                    self.assertEqual(ack[field], expected)
                self.assertEqual(ack['applicationState'], 'active')
                self.assertGreater(ack['wallTimeMS'], 0)
                self.assertGreater(ack['uptimeNS'], 0)
                self.assertEqual(ack['activeGeneration'], 0)
            self.assertNotIn('must-not-appear', result.stdout)
            self.assertNotIn('secret-token', result.stdout)


if __name__ == '__main__':
    unittest.main()
