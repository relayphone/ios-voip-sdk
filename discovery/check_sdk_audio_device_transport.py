#!/usr/bin/env python3
"""Offline packet binding and semantic tamper controls; no native execution."""
from copy import deepcopy
import json
from pathlib import Path
import shutil
import tempfile
import unittest

import sdk_audio_device_transport as gate


class TransportControls(unittest.TestCase):
    def setUp(self):
        self.packet = gate.ROOT / gate.PACKET
        self.rows = [json.loads(line) for line in (self.packet / 'device-trace.jsonl').read_text().splitlines()]
        self.receipt = json.loads((self.packet / 'receipt.json').read_text())

    def reject(self, edit, pattern):
        rows, receipt = deepcopy(self.rows), deepcopy(self.receipt)
        edit(rows, receipt)
        with self.assertRaisesRegex(gate.EvidenceError, pattern): gate.validate_transport(rows, receipt)

    def test_committed_packet_transport_pass_preserves_full_probe_red(self):
        result = gate.validate()
        self.assertTrue(result['transportSlicePassed'])
        self.assertTrue(result['notificationTransportExercised'])
        for field in ('fullFixturePassed', 'fourOperationsCompleted', 'resumptionRecommendationExercised',
                      'hardwareLCKInterruptionExercised', 'ciAttested'):
            self.assertIs(result[field], False)
        self.assertEqual(result['inventories']['raw.notification'], dict(active=2, inactive=3, recommended=0))

    def test_missing_empty_and_unbound_packet_fail(self):
        for mode in ('missing', 'empty', 'unbound', 'rebound-manifest'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(prefix='ios-voip-audio-packet-') as temp:
                packet = Path(temp) / 'packet'; shutil.copytree(self.packet, packet)
                path = packet / ('MANIFEST.json' if mode == 'rebound-manifest' else 'device-trace.jsonl')
                if mode == 'missing': path.unlink()
                else: path.write_text('' if mode == 'empty' else '{}\n')
                with self.assertRaises((gate.EvidenceError, OSError)): gate.validate(packet=packet)

    def test_current_shipping_source_must_match_measured_copy(self):
        with tempfile.TemporaryDirectory(prefix='ios-voip-audio-source-') as temp:
            root = Path(temp)
            for name in gate.AUDIO_FILES:
                target = root / name; target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(gate.ROOT / name, target)
            (root / gate.AUDIO_FILES[0]).write_text('different source\n')
            with self.assertRaisesRegex(gate.EvidenceError, 'current shipping audio'):
                gate.validate(source_root=root, packet=self.packet)

    def test_run_pid_simulator_main_and_launch_bindings(self):
        for field, value in (('runID', 'other'), ('pid', True), ('bundleID', 'other'), ('main', False)):
            self.reject(lambda rows, receipt: rows[10].update({field: value}), 'identity')
        self.reject(lambda rows, receipt: rows[0].update(simulator=True), 'build/launch')
        self.reject(lambda rows, receipt: rows[0].update(executableSHA256='0' * 64), 'build/launch')

    def test_raw_c_swift_missing_and_scalar_type_tampers(self):
        self.reject(lambda rows, receipt: rows[8].update(event='ignored'), 'inventory differs')
        self.reject(lambda rows, receipt: rows[9].update(source=False), 'scalar types')
        self.reject(lambda rows, receipt: rows[9].update(shouldResume=True), 'inventory differs')
        self.reject(lambda rows, receipt: rows[15].update(kind='unknown'), 'empty/unknown')

    def test_real_context_and_notification_name_required(self):
        self.reject(lambda rows, receipt: rows[17].update(contextClass='FakeContext'), 'typed inactive context')
        self.reject(lambda rows, receipt: rows[17].update(notificationName='private-control'), 'Apple notification name')
        self.reject(lambda rows, receipt: rows[17].update(source=2), 'typed inactive context')

    def test_private_sentinel_cannot_count_as_apple_notification(self):
        self.reject(lambda rows, receipt: rows[3].update(countsAsAVNotification=True), 'private sentinel')

    def test_observer_custody_and_audio_queue_required(self):
        self.reject(lambda rows, receipt: rows[1].update(actualSwiftConsumer=False), 'actual observer')
        self.reject(lambda rows, receipt: rows[12].update(callMain=True), 'actual audio queue')
        self.reject(lambda rows, receipt: receipt['build'].update(ciAttested=True), 'build/launch')

    def test_full_failed_probe_cannot_be_reclassified(self):
        self.reject(lambda rows, receipt: receipt['result'].update(fullFixturePassed=True), 'probe RED')
        self.reject(lambda rows, receipt: receipt['result'].update(fourOperationsCompleted=True), 'probe RED')
        self.reject(lambda rows, receipt: rows[30].update(engineRunning=True), 'probe RED')
        self.reject(lambda rows, receipt: receipt['result'].update(notRun=[]), 'operation scope')

    def test_owned_cleanup_and_caps_required(self):
        for key in ('ownedAppUninstalled', 'twoIndependentPIDAbsenceReadbacks', 'nativeStopDeadlineMet'):
            self.reject(lambda rows, receipt: receipt['cleanup'].update({key: False}), 'cleanup/caps')
        self.reject(lambda rows, receipt: receipt['cleanup'].update(launchToFirstPIDAbsenceSeconds=91), 'cleanup/caps')
        self.reject(lambda rows, receipt: rows[35].update(engineRunning=True), 'cleanup/caps')


if __name__ == '__main__':
    unittest.main()
