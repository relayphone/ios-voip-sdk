#!/usr/bin/env python3
"""Host policy controls; native NSError/callback acceptance lives in filtered_acceptance."""
from pathlib import Path
import re
import json
import hashlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class FilteredPolicyTests(unittest.TestCase):
    def test_negative_block_list_measurement_has_pinned_sources(self):
        profile = json.loads((ROOT / 'Sources/Engine/Resources/ios-27.0.json').read_text())
        evidence = profile['lckBlockedNumberEvidence']
        self.assertEqual((evidence['sourceIssue'], evidence['incomingErrorCode'], evidence['repeatAfterSeconds']), (85, 0, 66))
        self.assertEqual(evidence['verification'], 'measured-negative')
        self.assertNotIn('block-list', profile['incomingFilterPolicies'])
        for path, checksum in evidence['captures'].items():
            self.assertEqual(hashlib.sha256((ROOT / path).read_bytes()).hexdigest(), checksum)

    def test_filtered_report_selection_and_snapshot(self):
        source = (ROOT / 'Sources/Engine/RuntimeEngine.swift').read_text()
        definitions = ['private typealias IncomingFilterReason = ControlRequest.FilterReason']
        for kind, name in [('extension', 'ControlRequest.FilterReason'), ('struct', 'IncomingFilterPolicy'),
                           ('struct', 'IncomingReportOutcome'), ('struct', 'Faults')]:
            matches = re.findall(r'private ' + kind + ' ' + name + r'[^\n]*\{\n.*?\n\}', source, re.S)
            self.assertEqual(len(matches), 1, 'missing production filtered-report policy seam: ' + name)
            definitions.append(matches[0])
        checks = r'''
@main struct FilteredPolicyChecks {
  static func main() throws {
    let profile = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
    let bytes = try JSONSerialization.data(withJSONObject: profile["incomingFilterPolicies"]!)
    let policies = try JSONDecoder().decode([String: IncomingFilterPolicy].self, from: bytes)
    let expected: [(String, Int, String)] = [
      ("do-not-disturb", 3, "verified"),
      ("restricted-sharing-mode", 5, "unverified"), ("call-is-protected", 6, "unverified"),
      ("sensitive-participants", 7, "unverified")]
    precondition(IncomingFilterReason(rawValue: "garbage") == nil)
    precondition(IncomingFilterReason(rawValue: "block-list") == nil && policies["block-list"] == nil, "Device LCK block list does not reject incoming reports")
    for (name, code, verification) in expected {
      let reason = IncomingFilterReason(rawValue: name)!
      let policy = policies[name]!
      precondition(reason.code == code && policy.code == code)
      precondition(policy.delaySeconds == 2.07 && policy.verification == verification)
      precondition(!policy.evidence.isEmpty)
      let selected = IncomingReportOutcome(reason: reason, duplicate: false, policy: policy,
        normalDelaySeconds: 0.02, extraDelaySeconds: 0.4)
      precondition(selected.code == code && selected.domain == "com.apple.CallKit.error.incomingcall")
      precondition(selected.filterReason == name && selected.verification == verification)
      precondition(abs(selected.delaySeconds - 2.47) < 0.00001)
      let error = selected.error!
      precondition(error.code == code && error.domain == selected.domain, "completion must get the transparent NSError")
      let duplicate = IncomingReportOutcome(reason: reason, duplicate: true, policy: policy,
        normalDelaySeconds: 0.02, extraDelaySeconds: 0)
      precondition(duplicate.code == 2 && duplicate.delaySeconds == 0.02,
        "duplicate UUID preserves code2 priority and ordinary completion timing")
      precondition(duplicate.filterReason == "none" && duplicate.verification == "not-applicable")
      // A later selection cannot mutate a captured report's outcome or deadline.
      let cleared = IncomingReportOutcome(reason: .none, duplicate: false, policy: nil,
        normalDelaySeconds: 0.02, extraDelaySeconds: 0)
      precondition(cleared.error == nil && cleared.code == 0 && cleared.domain.isEmpty)
      precondition(selected.code == code && selected.filterReason == name && selected.delaySeconds > 2)
    }
    var settings = Faults()
    settings.apply([.staleAudio(true), .reportCallbackDelayMS(5000), .invalidateDuringHandoff(true)])
    settings.apply([.incomingErrorCode(4)])
    precondition(settings.staleAudio == true && settings.reportCallbackDelayMS == 5000 && settings.invalidateDuringHandoff == true && settings.incomingErrorCode == 4)
    settings.apply([.incomingErrorCode(0)])
    precondition(settings.reportCallbackDelayMS == 5000 && settings.incomingErrorCode == 0, "Clearing the explicit fault preserves unrelated faults")
    let fault = IncomingReportOutcome(reason: .none, duplicate: false, policy: nil,
      normalDelaySeconds: 0.02, extraDelaySeconds: 0.4, incomingErrorCode: 4)
    precondition(fault.code == 4 && fault.filterReason == "none" && fault.verification == "injected-fault")
    precondition(abs(fault.delaySeconds - 0.42) < 0.00001)
    let duplicateFault = IncomingReportOutcome(reason: .doNotDisturb, duplicate: true,
      policy: policies["do-not-disturb"], normalDelaySeconds: 0.02, extraDelaySeconds: 0, incomingErrorCode: 4)
    precondition(duplicateFault.code == 2 && duplicateFault.verification == "not-applicable")
    let clearFault = IncomingReportOutcome(reason: .none, duplicate: false, policy: nil,
      normalDelaySeconds: 0.02, extraDelaySeconds: 0, incomingErrorCode: 0)
    precondition(clearFault.error == nil && fault.code == 4, "A later clear cannot mutate an entered report")
    print("passed: filtered codes3,5-7 and explicit fault4, evidence classifications, latency, immutable snapshot, transparent NSError, duplicate priority, clear")
  }
}
'''
        with tempfile.TemporaryDirectory(prefix='filtered-policy-') as temporary:
            root = Path(temporary)
            swift = root / 'Policy.swift'
            swift.write_text('import Foundation\n' + '\n'.join(definitions) + '\n' + checks)
            binary = root / 'policy'
            result = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors',
                                     '-parse-as-library', *map(str, sorted((ROOT / 'Sources/CKSimProtocol').glob('*.swift'))),
                                     str(swift), '-o', str(binary)],
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(binary), str(ROOT / 'Sources/Engine/Resources/ios-27.0.json')],
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(result.stdout.startswith('passed:'), result.stdout)


if __name__ == '__main__':
    unittest.main()
