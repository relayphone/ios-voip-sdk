#!/usr/bin/env python3
"""Host controls for the simulator-only LCK probe readiness barrier."""
import hashlib
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
REFERENCE = ROOT / 'docs/research/callkit-simulator-probe/lck.swift'


def generated_probe(directory, reference=None):
    script = (ROOT / 'discovery/run.sh').read_text()
    blocks = re.findall(r'<<\'PYLCK\'\n(.*?)\nPYLCK', script, re.S)
    if len(blocks) != 1:
        raise ValueError('Require exactly one generated LCK probe adapter')
    output = directory / 'lck.swift'
    working = ROOT / 'discovery'
    if reference is not None:
        working = directory / 'adapter/discovery'
        working.mkdir(parents=True)
        frozen = working.parent / 'docs/research/callkit-simulator-probe/lck.swift'
        frozen.parent.mkdir(parents=True)
        frozen.write_text(reference)
    subprocess.run([sys.executable, '-c', blocks[0], str(output)],
                   cwd=working, check=True, capture_output=True, text=True, timeout=10)
    return output.read_text()


class ReadinessChecks(unittest.TestCase):
    def test_generated_probe_waits_for_observed_connection_before_snapshot_and_end(self):
        before = hashlib.sha256(REFERENCE.read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory(prefix='cksim-lck-readiness-') as temporary:
            source = generated_probe(Path(temporary))
        checkpoint = 'await sleep(2); await waitForOutgoingReadiness(id, tag); snapshot("\\(tag)-outgoing", m)'
        self.assertEqual(source.count(checkpoint), 1,
                         'The generated outgoing journey must await connection after the original two-second delay')
        self.assertIn('== "cx-after" { return }', source)
        self.assertIn('tap.observedConversationStates[id] == "joined"', source)
        self.assertIn('$0.uuid == id && $0.hasConnected && !$0.hasEnded', source)
        self.assertIn('probe/lck_readiness.swift', (ROOT / 'discovery/run.sh').read_text())
        self.assertIn('"livenessLimitSeconds": 10', source)
        self.assertIn('      exit(1)', source)
        self.assertEqual(hashlib.sha256(REFERENCE.read_bytes()).hexdigest(), before)

    def test_changed_historical_input_refuses_instead_of_silently_skipping_the_barrier(self):
        with tempfile.TemporaryDirectory(prefix='cksim-lck-anchor-') as temporary:
            with self.assertRaises(subprocess.CalledProcessError):
                generated_probe(Path(temporary), REFERENCE.read_text().replace('    await sleep(2); snapshot',
                                                                           '    await sleep(3); snapshot'))

    def test_actual_waiter_handles_ready_late_incomplete_timeout_and_cancellation(self):
        with tempfile.TemporaryDirectory(prefix='cksim-lck-waiter-') as temporary:
            directory = Path(temporary)
            tests = directory / 'tests.swift'
            tests.write_text('''import Foundation
@main struct ReadinessTests {
  @MainActor static func main() async {
    let observed = LCKProbeConversationStates(), id = UUID(), unrelated = UUID()
    precondition(observed[id] == nil)
    await Task.detached { observed.record(id, state: "joined") }.value
    precondition(observed[id] == "joined" && observed[unrelated] == nil)
    observed.record(id, state: "left")
    precondition(observed[id] == "left")
    precondition(LCKProbeReadiness.livenessLimit == .seconds(10))
    let immediate = await LCKProbeReadiness.wait { true }
    precondition(immediate)
    let incomplete = await LCKProbeReadiness.wait(limit: .zero) { false }
    precondition(!incomplete)
    let expiredReady = await LCKProbeReadiness.wait(limit: .milliseconds(1)) {
      Thread.sleep(forTimeInterval: 0.01)
      return true
    }
    precondition(!expiredReady, "A blocked main-actor readiness check cannot admit a result after its budget")
    var manager1 = false, manager2 = false, observerConnected = false
    let progress = Task { @MainActor in
      try await Task.sleep(for: .milliseconds(20))
      manager1 = true
      try await Task.sleep(for: .milliseconds(20))
      manager2 = true
      try await Task.sleep(for: .milliseconds(20))
      observerConnected = true
    }
    let delayed = await LCKProbeReadiness.wait { manager1 && manager2 && observerConnected }
    precondition(delayed && manager1 && manager2 && observerConnected)
    _ = try? await progress.value
    let cancelled = Task { @MainActor in await LCKProbeReadiness.wait { false } }
    cancelled.cancel()
    let cancelledResult = await cancelled.value
    precondition(!cancelledResult)
    print("actual waiter: ready, delayed readiness, incomplete timeout, cancellation")
  }
}
''')
            binary = directory / 'readiness-tests'
            compiled = subprocess.run(['swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
                str(ROOT / 'discovery/probe/lck_readiness.swift'), str(tests), '-o', str(binary)],
                capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            executed = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            self.assertEqual(executed.returncode, 0, executed.stdout + executed.stderr)


if __name__ == '__main__':
    unittest.main()
