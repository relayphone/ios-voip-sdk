#!/usr/bin/env python3
"""Offline positive and tamper controls for the M0 evidence gate."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import sdk_m0_conformance as gate

IDENTITY = dict(sourceCommit='a' * 40, sourceInputsSHA256='b' * 64)
SYMBOLS = sorted(['_main', '__swift_FORCE_LOAD_$_CKSimRuntime'])
CONVERSATION = '92064596-6918-40AE-93E7-3A488242FF26'


def write_json(path, value):
    path.write_text(json.dumps(value) + '\n')


def write_trace(root, name, rows):
    path = root / (name + '.log')
    for sequence, row in enumerate(rows, 1):
        row['sequence'] = sequence
    path.write_text(''.join('PROBE ' + json.dumps(row) + '\n' for row in rows))
    write_json(root / (name + '.receipt.json'), dict(schemaVersion=2, success=True,
        completed=True, terminateExitCode=0, launchExitCode=0, lastProbeEvent='done',
        appPID=123, launcherAppPID=123, runID='run-1', simulatorID='sim-1',
        bundleID=rows[0]['bundleID'], scenario=name, appEntryObserved=True,
        traceSHA256=gate.digest(path)))


def fixture(root):
    environment = dict(simulatorID='sim-1', simulatorRuntimeID='ios-27', simulatorOS='27.0',
                       xcodeVersion='27.1', sdkVersion='27.0', hostArchitecture='arm64')
    write_json(root / 'environment.json', environment)
    files, objects = {}, []
    for relative in [*gate.BINARIES.values(), *(f'device-objects/{target}.o' for target in gate.TARGETS)]:
        path = root / relative
        path.parent.mkdir(exist_ok=True)
        path.write_bytes(('synthetic ' + relative).encode())
        if relative in gate.BINARIES.values():
            files[relative] = gate.digest(path)
        if relative == gate.BINARIES['device'] or relative.startswith('device-objects/'):
            symbols = root / (relative + '.symbols')
            symbols.write_text('\n'.join(SYMBOLS) + '\n')
            if relative.startswith('device-objects/'):
                objects.append(dict(target=path.stem, path=relative, sha256=gate.digest(path),
                                    symbolsSHA256=gate.digest(symbols)))
    (root / 'build-logs').mkdir()
    (root / 'build-logs/build.log').write_text('synthetic build receipt\n')
    write_json(root / 'device-build.json', dict(product='unified-shared-source-device',
        target='arm64-apple-ios17.4', binarySHA256=files[gate.BINARIES['device']], **IDENTITY))
    write_json(root / 'source-before.json', IDENTITY)
    write_json(root / 'cleanup.json', dict(simulatorID='sim-1', deleted=True, deleteExitCode=0))
    installed = {key: files[gate.BINARIES[key]] for key in ('example', 'bootstrap', 'javascript')}
    write_json(root / 'installed.json', installed)
    write_json(root / 'runtime.json', dict(identifier='ios-27', version='27.0'))
    write_json(root / 'build-receipt.json', dict(schemaVersion=1, **IDENTITY, sourceStart=IDENTITY,
        files=files, swiftPMDeviceObjects=[{key: obj[key] for key in ('target', 'path', 'sha256')} for obj in objects]))
    manifest = dict(schemaVersion=1, scenario='sdk-m0', configuration='Release',
        runID='run-1', simulatorID='sim-1', ownsSimulator=True, runtimeInjectionRequested=False,
        **IDENTITY, files=files, swiftPMDeviceObjects=objects,
        environmentSHA256=gate.digest(root / 'environment.json'),
        deviceBuildSHA256=gate.digest(root / 'device-build.json'),
        sourceBeginSHA256=gate.digest(root / 'source-before.json'), cleanupSHA256=gate.digest(root / 'cleanup.json'),
        installedBinarySHA256=installed, installedSHA256=gate.digest(root / 'installed.json'),
        runtimeSHA256=gate.digest(root / 'runtime.json'),
        buildReceiptSHA256=gate.digest(root / 'build-receipt.json'),
        inheritedExternalDYLD=dict(present=False, sha256=hashlib.sha256(b'').hexdigest()),
        deviceSymbolsSHA256=gate.digest(root / (gate.BINARIES['device'] + '.symbols')),
        buildLogs={'build.log': gate.digest(root / 'build-logs/build.log')})
    write_json(root / 'manifest.json', manifest)
    def snapshot(revision, status, connected=False):
        return ('sdk.snapshot', dict(revision=revision, conversations=[dict(id=CONVERSATION,
            direction='incoming', status=status, isMuted=False, isVideo=False, hasConnectedAt=connected)]))
    events = [('app.entry', {}), ('launch', dict(mode='sdk-m0', traceVersion=2)),
        ('sdk.activation', dict(active=True)), ('sdk.managerCreated', {}),
        ('sdk.state', dict(state='idle')), ('sdk.incomingReported', {}), snapshot(0, 'ringing'), ('sdk.ringing', {}),
        ('sdk.action', dict(kind='JoinConversationAction')), snapshot(1, 'connecting'),
        ('sdk.joinSettled', {}), ('sdk.backendConnectedRequested', {}),
        snapshot(2, 'connected', connected=True), ('sdk.state', dict(state='joined')),
        ('sdk.joined', {}), ('sdk.action', dict(kind='EndConversationAction')),
        ('sdk.state', dict(state='left')), ('sdk.ended', {}), ('sdk.result', dict(success=True)), ('done', {})]
    def row(event, fields, index, bundle):
        return dict(event=event, t_ms=index + (1000 if index >= 6 else 0), main=True,
                    pid=123, runID='run-1', simulatorID='sim-1', bundleID=bundle, **fields)
    rows = [row(event, dict(fields, **({'conversationID': CONVERSATION}
        if event.startswith('sdk.') and event not in ('sdk.activation', 'sdk.managerCreated', 'sdk.result', 'sdk.snapshot') else {})),
        index, 'dev.iosvoipsdk.example') for index, (event, fields) in enumerate(events)]
    write_trace(root, 'sdk-m0', rows)
    for case in gate.CASES:
        labels = ['explicit-activation-required'] + (['activation-succeeds', 'successful-runtime-active', 'activation-idempotent']
            if case == 'healthy' else ['activation-refuses', 'refused-runtime-inactive',
                                      'all-root-concrete-action-push-imps-restored', 'refusal-idempotent'])
        events = [('launch', dict(mode=case, injected=False))] + [
            ('bootstrap.check', dict(label=label, passed=True)) for label in labels] + [
            ('done', dict(success=True, checks=len(labels), snapshots=60))]
        write_trace(root, 'bootstrap-' + case, [row(event, fields, index, 'dev.callkitsim.sdkbootstrap')
                    for index, (event, fields) in enumerate(events)])


def change_json(root, name, edit):
    path = root / name
    value = json.loads(path.read_text())
    edit(value)
    write_json(path, value)


def change_rows(root, edit, name='sdk-m0'):
    rows = gate.load(root, name)
    edit(rows)
    write_trace(root, name, rows)  # Rebind the hash so semantic checks must reject.


def change_bound_json(root, name, key, edit):
    change_json(root, name, edit)
    change_json(root, 'manifest.json', lambda item: item.update({key: gate.digest(root / name)}))


class Controls(unittest.TestCase):
    def capture_journals(self, mode):
        # Execute the actual M1 shell loop, replacing only its external services.
        source = (Path(__file__).parent / 'run_sdk_m0.sh').read_text()
        start = source.index('  mkdir "$OUT/m1"\n')
        end = source.index('  mkdir "$OUT/m1/contracts"\n', start)
        with tempfile.TemporaryDirectory(prefix='sdk-journal-host-') as temporary:
            root = Path(temporary)
            binaries, output, container = (root / name for name in ('bin', 'out', 'container'))
            binaries.mkdir(); output.mkdir()
            journal = container / 'Documents/.callkit-simulator/host-fixture/events.jsonl'
            journal.parent.mkdir(parents=True)
            services = {
                'xcrun': """import os,pathlib,sys,time
assert sys.argv[1:] == ['simctl','get_app_container','owned-fixture','dev.iosvoipsdk.example','data']
count=pathlib.Path(os.environ['FIXTURE_COUNT'])
n=int(count.read_text())+1 if count.exists() else 1
count.write_text(str(n)); mode=os.environ['FIXTURE_MODE']
if mode=='first-timeout' or (mode=='repeat-timeout' and n==3): time.sleep(3)
if mode=='failed-query': sys.exit(7)
if mode=='empty': print('')
elif mode=='missing-directory': print(os.environ['FIXTURE_CONTAINER']+'/absent')
else: print(os.environ['FIXTURE_CONTAINER'])
""",
                'python3': """import json,os,pathlib,sys
if sys.argv[1]=='discovery/run_scenario.py':
 args=sys.argv[2:]
 pathlib.Path(args[args.index('--output')+1]).write_text('fixture supervisor completed\\n')
 pathlib.Path(args[args.index('--receipt')+1]).write_text(json.dumps({'success':True,'completed':True}))
 pathlib.Path(os.environ['FIXTURE_JOURNAL']).write_text(json.dumps({'case':os.environ['SIMCTL_CHILD_SDK_M1_CASE']})+'\\n')
 sys.exit(0)
os.execv(sys.executable,[sys.executable,*sys.argv[1:]])
""",
            }
            for name, body in services.items():
                executable = binaries / name
                executable.write_text('#!' + sys.executable + '\n' + body)
                executable.chmod(0o755)
            driver = root / 'driver.sh'
            driver.write_text('set -euo pipefail\nOUT=' + shlex.quote(str(output)) +
                '\nRUN_ID=host-fixture\nUDID=owned-fixture\nINHERITED_DYLD=""\n' +
                # Keep asserting the production query asks for its original 30s.
                # Only the host fixture's alarm is shortened to one second.
                "limit() { test \"$1\" = 30; shift; perl -e 'alarm 1; exec @ARGV' \"$@\"; }\n" +
                source[start:end])
            result = subprocess.run(['/bin/bash', str(driver)], capture_output=True, text=True, timeout=8,
                env={**os.environ, 'PATH': f'{binaries}:/usr/bin:/bin', 'FIXTURE_MODE': mode,
                     'FIXTURE_COUNT': str(root / 'queries'), 'FIXTURE_CONTAINER': str(container),
                     'FIXTURE_JOURNAL': str(journal)})
            captured = {}
            for path in (output / 'm1').glob('*.runtime.jsonl'):
                receipt = json.loads(path.with_name(path.name.replace('.runtime.jsonl', '.receipt.json')).read_text())
                self.assertEqual(receipt['journalSHA256'], hashlib.sha256(path.read_bytes()).hexdigest())
                captured[path.stem] = json.loads(path.read_text())['case']
            return result, int((root / 'queries').read_text()), captured

    def test_relaunch_journals_do_not_repeat_container_service_queries(self):
        result, queries, captured = self.capture_journals('repeat-timeout')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(queries, 1)
        self.assertEqual(captured, {f'sdk-m1-{case}.runtime': case
                                   for case in ('journey', 'cold-launch', 'unhandled-expiry')})

    def test_initial_container_query_failure_is_preserved(self):
        for mode, status in (('first-timeout', 142), ('failed-query', 7)):
            with self.subTest(mode=mode):
                result, queries, captured = self.capture_journals(mode)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual(queries, 1)
                self.assertEqual(captured, {})

    def test_initial_container_must_be_a_nonempty_existing_directory(self):
        for mode in ('empty', 'missing-directory'):
            with self.subTest(mode=mode):
                result, queries, captured = self.capture_journals(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Missing owned example data container', result.stderr)
                self.assertEqual(queries, 1)
                self.assertEqual(captured, {})

    def check(self, edit=None, names=SYMBOLS, *, succeeds=False):
        with tempfile.TemporaryDirectory(prefix='cksim-sdk-m0-controls-') as temporary:
            root = Path(temporary)
            fixture(root)
            with patch.object(gate, 'source_identity', return_value=IDENTITY), \
                 patch.object(gate, 'symbol_names', return_value=names), \
                 patch.object(gate.subprocess, 'run', side_effect=AssertionError('native command forbidden')), \
                 patch.object(gate.subprocess, 'check_output', side_effect=AssertionError('subprocess forbidden')):
                if edit is not None:
                    edit(root)
                if edit is None or succeeds:
                    self.assertTrue(gate.validate(root)['success'])
                else:
                    with self.assertRaises((gate.EvidenceError, OSError, ValueError, KeyError, TypeError, StopIteration)):
                        gate.validate(root)

    def test_positive(self):
        self.check()

    def test_signal_receipts_integration(self):
        def signal_receipts(root):
            def signal(receipt):
                receipt.pop('terminateExitCode')
                receipt.update(terminationMethod='console-launcher-signal', launcherPID=456,
                    terminationSignal=15, terminationSignalDelivered=True, launchExitCode=-15,
                    consoleTransport='host-pty', appAbsenceMethod='signal-zero', appAbsentAfterStop=True)
            for name in ('sdk-m0', *(f'bootstrap-{case}' for case in gate.CASES)):
                change_json(root, name + '.receipt.json', signal)

        self.check(signal_receipts, succeeds=True)
        with tempfile.TemporaryDirectory(prefix='cksim-sdk-m0-signal-') as temporary:
            root = Path(temporary)
            fixture(root)
            signal_receipts(root)
            change_json(root, 'bootstrap-profile.receipt.json',
                        lambda receipt: receipt.pop('terminationSignalDelivered'))
            with self.assertRaises(gate.EvidenceError):
                gate.bootstrap_conformance(root)

    def test_required_markers(self):
        for event in ('app.entry', 'launch', 'sdk.activation', 'sdk.managerCreated', 'sdk.incomingReported',
                      'sdk.ringing', 'sdk.joinSettled', 'sdk.backendConnectedRequested',
                      'sdk.joined', 'sdk.ended', 'sdk.result', 'done'):
            for duplicate in (False, True):
                with self.subTest(event=event, duplicate=duplicate):
                    def edit(rows):
                        index = next(i for i, row in enumerate(rows) if row['event'] == event)
                        rows.insert(index, rows[index].copy()) if duplicate else rows.pop(index)
                    self.check(lambda root: change_rows(root, edit))

    def test_journey_semantics(self):
        for event, field, value in (('sdk.activation', 'active', False), ('sdk.result', 'success', False),
                ('sdk.result', 'error', 'synthetic SDK failure'),
                ('sdk.ringing', 't_ms', 900), ('sdk.joined', 'conversationID', 'wrong'),
                ('sdk.joined', 'pid', 999), ('sdk.joined', 'runID', 'other'), ('sdk.joined', 'main', False),
                ('sdk.joined', 'simulatorID', 'other'), ('sdk.action', 'kind', 'OtherAction')):
            with self.subTest(event=event, field=field):
                self.check(lambda root: change_rows(root, lambda rows: next(row for row in rows
                    if row['event'] == event).update({field: value})))
        for event in ('sdk.timeout', 'sdk.error'):
            self.check(lambda root: change_rows(root, lambda rows: rows.insert(-1, dict(rows[-2], event=event))))
        def boolean_sequence(root):
            path = root / 'sdk-m0.log'
            path.write_text(path.read_text().replace('"sequence": 1', '"sequence": true', 1))
            change_json(root, 'sdk-m0.receipt.json', lambda item: item.update(traceSHA256=gate.digest(path)))
        self.check(boolean_sequence)
        for state in ('idle', 'joined', 'left'):
            self.check(lambda root: change_rows(root, lambda rows: rows.__setitem__(slice(None),
                [row for row in rows if row.get('state') != state])))

    def test_backend_connection_projection(self):
        for field, value in (('status', 'connected'), ('hasConnectedAt', True), ('pending', dict(kind='join'))):
            with self.subTest(field=field):
                self.check(lambda root, field=field, value=value: change_rows(root, lambda rows:
                    next(row for row in rows if row['event'] == 'sdk.snapshot' and
                         row['conversations'][0]['status'] == 'connecting')['conversations'][0].update({field: value})))
        for field, value in (('hasConnectedAt', False), ('id', 'other-call'), ('status', 'connecting')):
            with self.subTest(connected_field=field):
                self.check(lambda root, field=field, value=value: change_rows(root, lambda rows:
                    next(row for row in rows if row['event'] == 'sdk.snapshot' and
                         row['conversations'][0]['status'] == 'connected')['conversations'][0].update({field: value})))
        self.check(lambda root: change_rows(root, lambda rows:
            rows.remove(next(row for row in rows if row['event'] == 'sdk.snapshot' and
                             row['conversations'][0]['status'] == 'connected'))))

    def test_backend_report_marker_identity_and_order(self):
        for event in ('sdk.joinSettled', 'sdk.backendConnectedRequested'):
            with self.subTest(event=event):
                self.check(lambda root, event=event: change_rows(root, lambda rows:
                    next(row for row in rows if row['event'] == event).update(conversationID='other-call')))
                self.check(lambda root, event=event: change_rows(root, lambda rows:
                    next(row for row in rows if row['event'] == event).pop('conversationID')))
        def move(rows, after_connected):
            marker = next(row for row in rows if row['event'] == 'sdk.backendConnectedRequested')
            rows.remove(marker)
            if after_connected:
                target = next(row for row in rows if row['event'] == 'sdk.snapshot' and
                              row['conversations'][0]['status'] == 'connected')
            else:
                target = next(row for row in rows if row['event'] == 'sdk.joinSettled')
            marker['t_ms'] = target['t_ms']
            rows.insert(rows.index(target) + int(after_connected), marker)
        for after_connected in (False, True):
            with self.subTest(after_connected=after_connected):
                self.check(lambda root, after_connected=after_connected: change_rows(root,
                    lambda rows: move(rows, after_connected)))

    def test_join_settlement_rejects_only_pre_join_connecting_snapshot(self):
        def move_before_join(rows):
            snapshot = next(row for row in rows if row['event'] == 'sdk.snapshot' and
                            row['conversations'][0]['status'] == 'connecting')
            action = next(row for row in rows if row['event'] == 'sdk.action' and
                          row['kind'] == 'JoinConversationAction')
            rows.remove(snapshot)
            snapshot['t_ms'] = action['t_ms']
            rows.insert(rows.index(action), snapshot)

        self.check(lambda root: change_rows(root, move_before_join))

    def test_artifact_binding(self):
        for field, value in (('schemaVersion', 0), ('configuration', 'Debug'), ('ownsSimulator', False),
                ('runtimeInjectionRequested', True), ('sourceCommit', 'c' * 40), ('sourceInputsSHA256', 'd' * 64)):
            self.check(lambda root: change_json(root, 'manifest.json', lambda item: item.update({field: value})))
        for relative in ('sdk-m0.log', 'environment.json', 'device-build.json', 'source-before.json',
                         'cleanup.json', 'installed.json', 'runtime.json', 'build-receipt.json', *gate.BINARIES.values(),
                         'device-objects/CKSimRuntime.o', 'binaries/device.symbols', 'build-logs/build.log'):
            with self.subTest(path=relative):
                self.check(lambda root: (root / relative).write_bytes(b'tampered'))
        self.check(lambda root: change_json(root, 'manifest.json', lambda item:
            item['installedBinarySHA256'].update(example='f' * 64)))
        self.check(lambda root: change_json(root, 'manifest.json', lambda item: item['swiftPMDeviceObjects'].pop()))
        for field in ('binarySHA256', 'sourceCommit', 'sourceInputsSHA256', 'target'):
            self.check(lambda root: change_bound_json(root, 'device-build.json', 'deviceBuildSHA256',
                lambda item: item.update({field: 'stale'})))
        self.check(lambda root: (root / 'cleanup.json').unlink())
        for field, value in (('simulatorID', 'other'), ('deleted', False), ('deleteExitCode', 1)):
            self.check(lambda root: change_bound_json(root, 'cleanup.json', 'cleanupSHA256',
                lambda item: item.update({field: value})))
        self.check(lambda root: change_bound_json(root, 'source-before.json', 'sourceBeginSHA256',
            lambda item: item.update(sourceInputsSHA256='f' * 64)))
        for name in ('installed.json', 'runtime.json'):
            self.check(lambda root: (root / name).unlink())
        for field in ('example', 'bootstrap', 'javascript'):
            self.check(lambda root: change_bound_json(root, 'installed.json', 'installedSHA256',
                lambda item: item.update({field: 'f' * 64})))
        for field in ('identifier', 'version'):
            self.check(lambda root: change_bound_json(root, 'runtime.json', 'runtimeSHA256',
                lambda item: item.update({field: 'other'})))
        self.check(lambda root: (root / 'build-receipt.json').unlink())
        for edit in (lambda item: item.update(sourceCommit='stale'),
                     lambda item: item['sourceStart'].update(sourceInputsSHA256='f' * 64),
                     lambda item: item['files'].update({'binaries/example': 'f' * 64}),
                     lambda item: item['swiftPMDeviceObjects'][0].update(sha256='f' * 64)):
            self.check(lambda root: change_bound_json(root, 'build-receipt.json', 'buildReceiptSHA256', edit))
        def missing_logs(root):
            (root / 'build-logs/build.log').unlink()
            change_json(root, 'manifest.json', lambda item: item.update(buildLogs={}))
        self.check(missing_logs)
        def empty_log(root):
            path = root / 'build-logs/build.log'
            path.write_text('')
            change_json(root, 'manifest.json', lambda item: item['buildLogs'].update({'build.log': gate.digest(path)}))
        self.check(empty_log)
        for field, value in (('completed', False), ('success', False), ('terminateExitCode', 1),
                ('lastProbeEvent', 'sdk.timeout'), ('appPID', 999), ('launcherAppPID', 999), ('runID', 'other')):
            self.check(lambda root: change_json(root, 'sdk-m0.receipt.json', lambda item: item.update({field: value})))
        self.check(lambda root: change_rows(root, lambda rows: rows[1].update(passed=False), 'bootstrap-profile'))

    def test_device_symbols(self):
        gate.validate_symbols(SYMBOLS + ['_$s12CKSimRuntime19resource_bundle_accessor'])
        for name in ('_CKSimRuntimeIsActive', '_CKSimGetEngine', '_CKSimFutureHook', '_OBJC_CLASS_$_CKSimulatorEngine',
                     '_$s13RuntimeEngine', '_$s16RuntimeBootstrap', '_providerInit', '_bindHook'):
            with self.subTest(symbol=name), self.assertRaises(gate.EvidenceError):
                gate.validate_symbols([name])
        self.check(lambda root: None, SYMBOLS + ['_CKSimGetEngine'])

    def test_device_object_paths(self):
        sources = dict(CKSimRuntimeC=('CKInterposition.o', 'CKPushDelivery.o'),
                       CKSimRuntime=('RuntimeEngine.o', 'resource_bundle_accessor.o'),
                       VoIPPlatform=('VSCompletionOnce.o', 'VSProviderCreationMonitor.o',
                                     'VSProviderMonitorInternal.o', 'VSPushRegistryOwner.o'),
                       VoIPSDK=('SimulatorSupport.o',))
        for suffix in ('.build', '-t.build'):
            with self.subTest(target_directory_suffix=suffix), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                intermediates = root / 'Build/Intermediates.noindex/VoIPSDK.build'
                expected = set()
                for target, names in sources.items():
                    for name in names:
                        path = intermediates / 'Release-iphoneos' / (target + suffix) / 'Objects-normal/arm64' / name
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_bytes(b'device object fixture')
                        expected.add((target, path))
                    for spelling in ('prefix-' + target + suffix, target + suffix + '-extra',
                                     target + '-test.build', target + '_t.build'):
                        path = intermediates / 'Release-iphoneos' / spelling / 'counterfeit.o'
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_bytes(b'counterfeit target fixture')
                    simulator = intermediates / 'Release-iphonesimulator' / (target + suffix) / 'simulator.o'
                    simulator.parent.mkdir(parents=True, exist_ok=True)
                    simulator.write_bytes(b'simulator object fixture')
                    product = root / 'Build/Products/Release-iphoneos' / (target + '.o')
                    product.parent.mkdir(parents=True, exist_ok=True)
                    product.write_bytes(b'combined product fixture')
                found = list(gate.device_objects(root))
                self.assertEqual({(target, source) for target, _, source in found}, expected)
                self.assertEqual(len(found), sum(len(names) for names in sources.values()))
                for missing in gate.TARGETS:
                    paths = [path for target, path in expected if target == missing]
                    for path in paths:
                        path.unlink()
                    with self.subTest(missing_target=missing), self.assertRaises(gate.EvidenceError):
                        list(gate.device_objects(root))
                    for path in paths:
                        path.write_bytes(b'device object fixture')


if __name__ == '__main__':
    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(Controls))
    print(json.dumps(dict(success=result.wasSuccessful(), testGroups=result.testsRun)))
    raise SystemExit(0 if result.wasSuccessful() else 1)
