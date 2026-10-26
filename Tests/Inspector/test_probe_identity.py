"""Exercise the real receipt writer with bundled and unbundled host processes."""
import json
import os
from pathlib import Path
import plistlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import shutil
import subprocess
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[2]
BUNDLE_ID = 'dev.callkitsim.probe-identity-host-test'
NONCE = 'EE6BFAF4-CF08-45FB-9801-F85B4E437DE0'
TOKEN = 'probe-token-secret-must-not-appear'
CANARY = 'unrelated-environment-secret-must-not-appear'
HARNESS = r'''
import Foundation
@main @MainActor struct ProbeIdentityTest {
  static func main() async throws {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let receipt = documents.appendingPathComponent("cksim-inspector-results.json")
    let model = InspectorModel()
    let following = Task { await model.follow() }
    defer { following.cancel() }
    var snapshots: [[String: Any]] = []
    let deadline = Date().addingTimeInterval(5)
    while snapshots.count < 2 {
      precondition(Date() < deadline, "Inspector did not publish two online receipts")
      try await Task.sleep(for: .milliseconds(10))
      if let data = try? Data(contentsOf: receipt),
         let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
         value["online"] as? Bool == true,
         let wall = value["wallTimeMS"] as? Int64,
         wall > (snapshots.last?["wallTimeMS"] as? Int64 ?? 0) {
        snapshots.append(value)
      }
    }
    let output: [String: Any] = ["documents": documents.path, "snapshots": snapshots]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output))
  }
}
'''


class ProbeIdentityTests(unittest.TestCase):
    def test_receipt_uses_actual_bundle_and_canonical_documents_parent_without_secrets(self):
        session = dict(schemaVersion=1, bundleID='dev.callkitsim.target', runID='probe-identity-test',
                       pid=2468, profile='ios-27.0')
        row = dict(schemaVersion=1, bundleID=session['bundleID'], runID=session['runID'], pid=session['pid'],
                   sequence=1, t_ms=10, event='call.changed', uuid='call-a',
                   connected=True, held=False, ended=False)
        failures = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                if self.headers.get('Authorization') != 'Bearer ' + TOKEN:
                    failures.append('Missing probe authorization')
                if self.path not in ('/events?after=0', '/events?after=1'):
                    failures.append('Unexpected probe route: ' + self.path)
                payload = json.dumps(dict(session=session, events=[row] if self.path.endswith('=0') else [],
                                          cursor=1)).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        serving = threading.Thread(target=server.serve_forever, daemon=True)
        serving.start()
        try:
            with tempfile.TemporaryDirectory(prefix='inspector-probe-identity-') as directory:
                work = Path(directory)
                source = (ROOT / 'Inspector/InspectorModel.swift').read_text().splitlines()
                self.assertEqual((source[0], source[-1]), ('#if targetEnvironment(simulator)', '#endif'))
                model, harness = work / 'InspectorModel.swift', work / 'Main.swift'
                model.write_text('\n'.join(source[1:-1]) + '\n')
                harness.write_text(HARNESS)
                bundle = work / 'ProbeIdentity.app' / 'Contents'
                executable = bundle / 'MacOS' / 'ProbeIdentity'
                executable.parent.mkdir(parents=True)
                with (bundle / 'Info.plist').open('wb') as output:
                    plistlib.dump(dict(CFBundleIdentifier=BUNDLE_ID, CFBundleExecutable=executable.name,
                                       CFBundlePackageType='APPL'), output)
                compiled = subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library',
                    '-module-cache-path', str(work / 'module-cache'), str(model),
                    *(str(ROOT / 'Inspector' / name) for name in
                      ('RuntimeEvent.swift', 'RuntimeTimingReferences.swift')),
                    str(harness), '-o', str(executable)], text=True, capture_output=True, timeout=60)
                self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
                unbundled = work / 'unbundled-probe'
                shutil.copy2(executable, unbundled)
                endpoint = f'http://127.0.0.1:{server.server_port}'
                for bundled, binary in ((True, executable), (False, unbundled)):
                    with self.subTest(bundled=bundled):
                        container = work / ('bundled-container' if bundled else 'host-container')
                        documents = container / 'Documents'
                        documents.mkdir(parents=True)
                        fixture_home = work / ('bundled-home' if bundled else 'host-home')
                        fixture_home.mkdir()
                        (fixture_home / 'Documents').symlink_to(documents, target_is_directory=True)
                        environment = dict(os.environ, CFFIXED_USER_HOME=str(fixture_home),
                            CKSIM_INSPECTOR_URL=endpoint, CKSIM_INSPECTOR_TOKEN=TOKEN,
                            CKSIM_INSPECTOR_PROBE_NONCE=NONCE, PROBE_SECRET_CANARY=CANARY,
                            CKSIM_INSPECTOR_BUNDLE_ID='counterfeit-bundle',
                            CKSIM_INSPECTOR_DATA_CONTAINER='/counterfeit/container')
                        result = subprocess.run([str(binary)], env=environment, text=True, capture_output=True, timeout=10)
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        output = json.loads(result.stdout)
                        self.assertEqual(Path(output['documents']), fixture_home / 'Documents')
                        snapshots = output['snapshots']
                        self.assertLess(snapshots[0]['wallTimeMS'], snapshots[1]['wallTimeMS'])
                        self.assertEqual(snapshots[0]['startedWallTimeMS'], snapshots[1]['startedWallTimeMS'])
                        self.assertEqual(snapshots[0]['inspectorPID'], snapshots[1]['inspectorPID'])
                        for snapshot in snapshots:
                            self.assertEqual(snapshot.get('inspectorBundleID'), BUNDLE_ID if bundled else None)
                            self.assertEqual(snapshot.get('inspectorDataContainer'), str(container.resolve()))
                            self.assertEqual(snapshot['nonce'], NONCE)
                            self.assertIs(type(snapshot['inspectorPID']), int)
                            self.assertGreater(snapshot['inspectorPID'], 0)
                            self.assertEqual(snapshot['session'], session)
                            self.assertEqual(snapshot['cursor'], 1)
                            self.assertEqual(snapshot['timeline'], [row])
                            self.assertEqual(snapshot['conversations'], [row])
                            self.assertEqual(snapshot['pending'], [])
                            self.assertTrue(snapshot['online'])
                            encoded = json.dumps(snapshot)
                            for secret in (TOKEN, CANARY, endpoint, 'counterfeit-bundle', '/counterfeit/container'):
                                self.assertNotIn(secret, encoded)
                        self.assertEqual(json.loads((documents / 'cksim-inspector-results.json').read_text()), snapshots[-1])
                self.assertEqual(failures, [])
        finally:
            server.shutdown()
            server.server_close()
            serving.join(timeout=2)


if __name__ == '__main__':
    unittest.main()
