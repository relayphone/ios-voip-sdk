#!/usr/bin/env python3
"""Offline completed no-I/O packet controls; no app, compiler or device use."""
from copy import deepcopy
import json
from pathlib import Path
import shutil
import tempfile
import unittest

import sdk_audio_device_noio_transport as gate


class NoIOTransportControls(unittest.TestCase):
    def setUp(self):
        self.packet = gate.ROOT / gate.PACKET
        self.rows = [json.loads(line) for line in (self.packet / 'device-trace.jsonl').read_text().splitlines()]
        self.receipt = json.loads((self.packet / 'receipt.json').read_text())

    def reject(self, edit, pattern):
        rows, receipt = deepcopy(self.rows), deepcopy(self.receipt)
        edit(rows, receipt)
        with self.assertRaisesRegex(gate.EvidenceError, pattern): gate.validate_transport(rows, receipt)

    def row(self, rows, event, **fields):
        return gate.one(rows, event, **fields)

    def test_completed_packet_and_separate_scopes(self):
        result = gate.validate()
        self.assertTrue(result['fullNoIOComplete'])
        self.assertTrue(result['ordinaryPhysicalProducerDecoderConsumerQualified'])
        self.assertEqual(result['inventories']['raw.notification'], dict(active=2, inactive=4, recommended=0))
        self.assertEqual(result['ioSnapshots'], 9)
        for key in ('silentRenderingExercised', 'hardwareLCKInterruptionExercised',
                    'resumptionRecommendationExercised', 'ciAttested'):
            self.assertIs(result[key], False)
        # Actual observers ran consumer→decoder→raw. Cleanup needed no extra API call.
        self.assertEqual([r['event'] for r in self.rows[8:11]],
                         ['consumer.lifecycle', 'decoder.lifecycle', 'raw.notification'])
        self.assertIs(self.row(self.rows, 'fixture.cleanup')['sessionAttempted'], False)

    def test_missing_empty_and_rebound_packet_fail(self):
        for mode in ('missing', 'empty', 'changed', 'rebound-manifest'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(prefix='ios-voip-noio-') as temp:
                packet = Path(temp) / 'packet'; shutil.copytree(self.packet, packet)
                path = packet / ('MANIFEST.json' if mode == 'rebound-manifest' else 'device-trace.jsonl')
                if mode == 'missing': path.unlink()
                else: path.write_text('' if mode == 'empty' else '{}\n')
                with self.assertRaises((gate.EvidenceError, OSError)): gate.validate(packet=packet)

    def test_shared_measured_source_must_match(self):
        with tempfile.TemporaryDirectory(prefix='ios-voip-noio-shared-') as temp:
            shared = Path(temp) / 'shared'; shutil.copytree(gate.ROOT / gate.old.PACKET, shared)
            (shared / 'probe/Probe.swift').write_text('unmeasured\n')
            with self.assertRaisesRegex(gate.EvidenceError, 'shared source'):
                gate.validate(shared_packet=shared)

    def test_current_eight_audio_sources_must_match(self):
        with tempfile.TemporaryDirectory(prefix='ios-voip-noio-source-') as temp:
            root = Path(temp)
            for name in gate.old.AUDIO_FILES:
                path = root / name; path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(gate.ROOT / name, path)
            (root / gate.old.AUDIO_FILES[0]).write_text('unmeasured\n')
            with self.assertRaisesRegex(gate.EvidenceError, 'current shipping audio'):
                gate.validate(source_root=root, packet=self.packet, shared_packet=gate.ROOT / gate.old.PACKET)

    def test_run_pid_main_and_launch_mode(self):
        for key, value in (('runID', 'other'), ('pid', True), ('main', False), ('bundleID', 'other')):
            self.reject(lambda rows, receipt: rows[10].update({key: value}), 'identity')
        for key, value in (('silentOutputRequested', True), ('simulator', True), ('executableSHA256', '0' * 64)):
            self.reject(lambda rows, receipt: rows[0].update({key: value}), 'launch')

    def test_four_real_operations_are_required(self):
        self.reject(lambda rows, receipt: self.row(rows, 'operation.requested', phase='async-deactivate').update(event='ignored'), 'four operations')
        self.reject(lambda rows, receipt: self.row(rows, 'operation.requested', phase='async-deactivate').update(index=True), 'operation order')
        for key, value in (('sessionSuccess', False), ('ioSuccess', False), ('sessionErrorCode', False),
                           ('callMain', True), ('callAudioQueue', False)):
            self.reject(lambda rows, receipt: self.row(rows, 'operation.result', phase='async-deactivate').update({key: value}), 'actual API')

    def test_observation_and_foreground_are_required(self):
        for key, value in (('observationElapsedMS', 1), ('mainHeartbeatTicks', 0)):
            self.reject(lambda rows, receipt: self.row(rows, 'operation.observed', phase='async-activate').update({key: value}), 'observation')
        self.reject(lambda rows, receipt: self.row(rows, 'operation.requested', phase='async-activate').update(applicationActive=False), 'operation order')

    def test_nine_typed_zero_io_snapshots_are_required(self):
        for key, value in (('engineRunning', True), ('renderFrames', 1), ('renderCallbacks', False)):
            self.reject(lambda rows, receipt: self.row(rows, 'operation.observed', phase='async-activate').update({key: value}), 'zero-I/O')
        self.reject(lambda rows, receipt: self.row(rows, 'fixture.cleanup').pop('renderFrames'), 'zero-I/O')

    def test_actual_stream_scalar_types_order_and_context_are_required(self):
        for key, value in (('source', False), ('shouldResume', True), ('phase', 'async-activate')):
            self.reject(lambda rows, receipt: self.row(rows, 'decoder.lifecycle', phase='sync-activate').update({key: value}), 'scalar')
        for key, value in (('contextClass', 'Fake'), ('source', 2), ('notificationName', 'private-control')):
            self.reject(lambda rows, receipt: next(r for r in rows if r['event'] == 'raw.notification' and r['kind'] == 'inactive').update({key: value}), 'raw context')
        for value in (True, 1.0):
            self.reject(lambda rows, receipt: receipt['observations'].update(rawInactiveSource=value), 'raw context')
        self.reject(lambda rows, receipt: self.row(rows, 'decoder.lifecycle', phase='sync-activate').update(event='ignored'), 'scalar')

    def test_known_extra_notifications_are_separate(self):
        self.reject(lambda rows, receipt: self.row(rows, 'raw.notification', kind='route', phase='sync-activate').update(kind='unknown'), 'lifecycle kind')
        self.reject(lambda rows, receipt: self.row(rows, 'raw.notification', kind='route', phase='sync-activate').update(notificationName='private-control'), 'raw context')
        self.reject(lambda rows, receipt: receipt['observations']['nonTargetNotificationCounts']['raw.notification'].update(route=5), 'observed inventory')

    def test_private_sentinel_and_actual_observers_are_required(self):
        self.reject(lambda rows, receipt: self.row(rows, 'control.privateSentinelPosted').update(countsAsAVNotification=True), 'observer/control')
        self.reject(lambda rows, receipt: self.row(rows, 'observers.installed').update(actualSwiftConsumer=False), 'observer/control')

    def test_completion_cannot_hide_a_failure(self):
        self.reject(lambda rows, receipt: self.row(rows, 'experiment.completed').update(event='experiment.failed'), 'incomplete/failed')
        self.reject(lambda rows, receipt: self.row(rows, 'experiment.completed').update(operations=True), 'completion')
        self.reject(lambda rows, receipt: receipt['result'].update(ordinaryPhysicalProducerDecoderConsumerQualified=False), 'result')

    def test_observed_receipt_facts_cannot_drift(self):
        self.reject(lambda rows, receipt: receipt['observations']['phases'][0].update(mainHeartbeatTicks=1), 'observation receipt')
        self.reject(lambda rows, receipt: receipt['observations'].update(mainThreadStallThresholdQualified=True), 'observation receipt')
        self.reject(lambda rows, receipt: receipt['result'].update(recommendationMeasured=True), 'result')

    def test_cleanup_and_local_custody_are_required(self):
        for key in ('ownedAppUninstalled', 'twoIndependentPIDAbsenceReadbacks', 'nativeStopDeadlineMet'):
            self.reject(lambda rows, receipt: receipt['cleanup'].update({key: False}), 'cleanup/caps')
        self.reject(lambda rows, receipt: receipt['cleanup'].update(launchRequestToIndependentPIDAbsenceSeconds=91), 'cleanup/caps')
        self.reject(lambda rows, receipt: receipt['build'].update(ciAttested=True), 'launch')


if __name__ == '__main__':
    unittest.main()
