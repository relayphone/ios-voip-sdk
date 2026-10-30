#!/usr/bin/env python3
"""Synthetic logical-gate controls; no native acceptance is claimed here."""
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import io
import json
import os
import shutil
import signal
import subprocess
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch
import tempfile
import uuid

import check_sdk_m1 as legacy
import sdk_system_conformance as gate

WALL = 1792627200000
SESSION = dict(schemaVersion=1, runID='synthetic-system-run', pid=12345, bundleID=gate.BUNDLE,
               profile='ios-27.0', controlTransport='directory-watch-v1')
SERVICES = 'PID\tStatus\tLabel\n-\t0\tUIKitApplication:' + gate.BUNDLE + '[synthetic-stopped]\n'
EXPIRY_SECONDS = dict(join=64, end=5.3, hold=5.3, mute=30, tones=30)
PROFILE = dict(lckActionDeadlineSeconds=30, lckMultiCall=dict(joinExpirySeconds=64, pauseEndExpirySeconds=5.3))


def iso(value):
    return datetime.fromtimestamp(value / 1000, timezone.utc).isoformat()


class Fixture:
    def __init__(self, case, expected, report_start_ms=1):
        self.case, self.expected = case, expected
        self.report_start_ms = report_start_ms
        self.rows, self.engine, self.controls, self.commands = [], [], [], []
        self.index = dict(bindings=[], controls=[], fixtureCommands=[])
        self.calls, self.clock, self.serial, self.revision = {}, 0, 0, 0
        self.launch_receipt = None
        self.app('app.entry')
        self.app('launch', mode='sdk-system', case=case, traceVersion=2)
        self.app('sdk.activation', active=True)
        self.app('sdk.managerCreated', owner='VoIPApplication.start')
        self.snapshot()
        self.hook()
        if case != 'push-launch': self.app('system.handlerAttached', attached=True)
        self.native('runtime.installed', version='synthetic')
        self.native('provider.created')
        clock = self.native('system.clock')['t_ms']
        self.app('system.ready', attached=case != 'push-launch', clockBeforeMS=WALL + clock)

    def uuid(self):
        self.serial += 1
        return str(uuid.UUID(int=self.serial)).upper()

    def app(self, event, **fields):
        self.clock += 1
        row = dict(event=event, sequence=len(self.rows) + 1, t_ms=self.clock, wallTimeMS=WALL + self.clock,
                   main=True, runID=SESSION['runID'], pid=SESSION['pid'], bundleID=gate.BUNDLE,
                   simulatorID='synthetic-simulator', **fields)
        self.rows.append(row)
        return row

    def native(self, event, **fields):
        self.clock += 1
        row = dict(event=event, sequence=len(self.engine) + 1, t_ms=self.clock,
                   runID=SESSION['runID'], pid=SESSION['pid'], bundleID=gate.BUNDLE,
                   profile='ios-27.0', provider='synthetic-provider', **fields)
        self.engine.append(row)
        return row

    def snapshot(self):
        row = self.app('sdk.snapshot', revision=self.revision, conversations=deepcopy(list(self.calls.values())))
        self.revision += 1
        return row

    def hook(self, binding=None):
        call = self.calls.get(binding['conversationID']) if binding else None
        self.app('system.hook', count=len(self.calls), conversationID=call['id'] if call else None,
                 status=call['status'] if call else None, hasConnectedAt=bool(call and call['hasConnectedAt']),
                 muted=bool(call and call['isMuted']))

    def control(self, operation, **fields):
        request = dict((key, SESSION[key]) for key in ('runID', 'pid', 'bundleID'))
        request.update(id=self.uuid(), operation=operation, **fields)
        control = dict(schemaVersion=1, session=SESSION.copy(), request=request,
                       response=dict((key, request[key]) for key in ('runID', 'pid', 'bundleID', 'id')))
        control['response'].update(success=True, result={})
        self.index['controls'].append(f'control-{len(self.controls):02}.json')
        self.controls.append(control)
        return control

    def command(self, operation, binding=None, body=None, server_call=None):
        command = dict(id=self.uuid(), runID=SESSION['runID'], case=self.case, pid=SESSION['pid'], operation=operation)
        if binding: command['conversationID'] = binding['conversationID']
        if server_call: command['serverCallId'] = server_call
        self.index['fixtureCommands'].append(f'fixture-{len(self.commands):02}.json')
        self.commands.append(command)
        self.app('system.commandReceived', id=command['id'], operation=operation)
        if body: body(command)
        self.app('system.commandCompleted', id=command['id'], operation=operation)
        return command

    def push(self, role, duplicate=False, cold=False):
        payload = dict(incomingCall=dict(eventId='synthetic-' + role, serverCallId='synthetic-server-' + role))
        if cold:
            push_id = self.uuid()
            envelope = dict(schemaVersion=1, id=push_id, runID=SESSION['runID'], bundleID=gate.BUNDLE,
                            createdAtMS=WALL, expiresAtMS=WALL + 30000, mustReport=True, payload=payload)
            digest = hashlib.sha256((json.dumps(envelope, sort_keys=True) + '\n').encode()).hexdigest()
            self.launch_receipt = dict(schemaVersion=1, simulatorID='synthetic-simulator', bundleID=gate.BUNDLE,
                runID=SESSION['runID'], pushID=push_id, envelope=envelope, envelopeSHA256=digest,
                mode=0o600, appServiceAbsent=True, runtimeInjectionRequested=False,
                serviceQuery=SERVICES, serviceQuerySHA256=hashlib.sha256(SERVICES.encode()).hexdigest())
            self.native('push.launchConsumed', pushID=push_id, envelopeSHA256=digest,
                        createdAtMS=WALL, expiresAtMS=WALL + 30000)
        else:
            control = self.control('push', payload=payload, mustReport=not duplicate)
            push_id = control['request']['id']
            control['response']['result'] = dict(scheduled=True, pushID=push_id)
        self.native('push.received', pushID=push_id, api='metadata', mustReport=not duplicate)
        if not duplicate:
            binding = dict(role=role, conversationID=self.uuid(), callUUID=self.uuid(), pushID=push_id)
            self.clock += self.report_start_ms - 1
            report = self.native('report.incoming', pushID=push_id, callUUID=binding['callUUID'])
            if self.case == 'answered-elsewhere':
                self.native('call.changed', uuid=binding['callUUID'], ended=False, ringing=True)
            self.calls[binding['conversationID']] = dict(id=binding['conversationID'], direction='incoming', status='ringing',
                                                       isMuted=False, isVideo=False, hasConnectedAt=False)
            snapshot = self.snapshot()
            binding.update(reportSequence=report['sequence'], snapshotSequence=snapshot['sequence'])
            self.index['bindings'].append(binding)
        else:
            binding = self.index['bindings'][0]
            self.native('report.incoming', pushID=push_id, callUUID=binding['callUUID'])
        self.native('push.callbackReturned', pushID=push_id, mustReport=not duplicate, reportEntered=True)
        self.native('report.completed', pushID=push_id, callUUID=binding['callUUID'], error=2 if duplicate else 0)
        self.native('push.completed', pushID=push_id, mustReport=not duplicate, reportEntered=True)
        return None if duplicate else binding

    def transaction(self, specs, control=None, origin='system', signal=True):
        ids = [self.uuid() for _ in specs]
        delivered = self.native('transaction.delivered', transactionID=self.uuid(), requestID=control['request']['id'] if control else origin,
                                origin=origin, actionIDs=ids, kinds=[gate.NATIVE[kind] for kind, _, _ in specs],
                                callUUIDs=[binding['callUUID'] for _, binding, _ in specs], parameters=[params for _, _, params in specs])
        if control: control['response']['result'] = dict(actionIDs=ids)
        actions = []
        for identity, (kind, binding, params) in zip(ids, specs):
            issued = WALL + self.clock
            deadline = self.native('action.deadline', actionID=identity, apiKind='livecommunicationkit',
                                   deadlineMS=issued + 30000, deadlineSeconds=30,
                                   expirySeconds=EXPIRY_SECONDS[kind], issuedAtMS=issued,
                                   expiryMS=issued + round(EXPIRY_SECONDS[kind] * 1000))
            cap = {'hold': 5300, 'end': 5300, 'join': 64000}.get(kind)
            selected = min(deadline['deadlineMS'], WALL + delivered['t_ms'] + cap) if cap else deadline['deadlineMS']
            action = dict(id=identity, kind=kind, binding=binding, params=params, origin=origin,
                          deadline=iso(selected - (3000 if kind in ('start', 'join') else 1500)), handled=False)
            actions.append(action)
            if signal: self.handler(action)
        return actions

    def handler(self, action):
        action['handled'] = True
        kind, binding, origin = action['kind'], action['binding'], action['origin']
        origin = 'app' if origin == 'application' else origin
        call = self.calls[binding['conversationID']]
        call['pending'] = dict(id=self.uuid(), kind=kind, origin=origin, deadline=action['deadline'])
        if kind == 'join': call['status'] = 'connecting'
        if kind == 'end': call['status'] = 'ending'
        self.snapshot()
        row = self.app('system.handler', kind=kind, conversationID=binding['conversationID'], origin=origin,
                       deadline=action['deadline'], **action['params'])
        self.native('system.handlerEntered', traceSequence=row['sequence'], kind=kind,
                    conversationID=binding['conversationID'], origin=origin, deadline=action['deadline'], **action['params'])

    def settle(self, actions):
        for action in actions:
            self.native('action.settled', actionID=action['id'], fulfilled=True, expired=False, origin=action['origin'])
            call = self.calls.get(action['binding']['conversationID'])
            if action['origin'] == 'muteEcho' or not call or action['kind'] == 'mute' and not action['handled']: continue
            call.pop('pending', None)
            if action['kind'] == 'end': self.calls.pop(call['id'])
            elif action['kind'] == 'hold': call['status'] = 'held'
            elif action['kind'] == 'mute': call['isMuted'] = action['params']['muted']
        self.snapshot()
        for binding in self.index['bindings']:
            if binding['conversationID'] in self.calls: self.hook(binding)
        if not self.calls: self.hook()

    def action(self, operation, binding):
        control = self.control(operation, callUUID=binding['callUUID'])
        actions = self.transaction([('join' if operation == 'answer' else 'end', binding, {})], control,
                                   signal=self.case != 'push-launch' or operation != 'answer')
        if self.case == 'push-launch' and operation == 'answer':
            call = self.calls[binding['conversationID']]
            call['status'] = 'connecting'
            call['pending'] = dict(id=self.uuid(), kind='join', origin='system', deadline=actions[0]['deadline'])
            self.snapshot()
            self.command('attach-handler', body=lambda command: (self.app('system.handlerAttached', attached=True), self.handler(actions[0])))
        self.settle(actions)

    def connected(self, binding):
        def report(command):
            self.app('system.backendConnected', id=command['id'], conversationID=binding['conversationID'])
            self.calls[binding['conversationID']].update(status='connected', hasConnectedAt=True)
            self.snapshot()
            self.hook(binding)
        self.command('backend-connected', binding, report)

    def build(self):
        first = self.push('first', cold=self.case == 'push-launch')
        if self.case == 'decline': self.action('decline', first)
        elif self.case == 'answered-elsewhere':
            def signal(command):
                context = dict(id=command['id'], eventId=command['id'], serverCallId='synthetic-server-first',
                               conversationID=first['conversationID'])
                marker = self.native('system.answeredElsewhereSignal', traceSequence=len(self.rows) + 1, **context)
                self.app('system.answeredElsewhereRequested', clockBeforeMS=WALL + marker['t_ms'], **context)
                self.native('report.ended', callUUID=first['callUUID'], pushID=first['pushID'], reason=4)
                self.native('call.changed', uuid=first['callUUID'], ended=True, ringing=False)
                self.calls[first['conversationID']].update(status='ended', endedReason='answeredElsewhere')
                self.snapshot()
                self.app('system.event', name='answeredElsewhere', **{key: value for key, value in context.items() if key != 'id'})
                self.calls.clear()
                self.snapshot()
                self.hook()
                self.app('system.answeredElsewhereAccepted', accepted=True, **context)
            self.command('answered-elsewhere', first, signal, server_call='synthetic-server-first')
        else:
            self.action('answer', first)
            self.connected(first)
            if self.case in ('hold-accept', 'end-accept'):
                waiting = self.push('waiting')
                operation = 'hold-and-accept' if self.case == 'hold-accept' else 'end-and-accept'
                control = self.control(operation, callUUID=waiting['callUUID'], activeCallUUID=first['callUUID'])
                bindings = dict(active=first, waiting=waiting)
                reverse = {value: key for key, value in gate.NATIVE.items()}
                specs = [(reverse[item['kind']], bindings[item['role']], {'held': item['onHold']} if 'onHold' in item else {})
                         for item in self.expected[operation]]
                self.settle(self.transaction(specs, control))
                self.connected(waiting)
                self.action('end', waiting)
                if self.case == 'hold-accept': self.action('end', first)
            elif self.case == 'mute-echo':
                control = self.control('mute', callUUID=first['callUUID'], muted=True)
                self.settle(self.transaction([('mute', first, {'muted': True})], control))
                self.push('first', duplicate=True)
                pending = []
                self.command('app-mute', first, lambda command: pending.extend(self.transaction([('mute', first, {'muted': False})], origin='application')))
                rejected = self.control('reset')
                rejected['response'].update(success=False, error='selected-provider reset requires no pending runtime actions')
                self.native('control.rejected', requestID=rejected['request']['id'], operation='reset', error=rejected['response']['error'])
                control = self.control('mute', callUUID=first['callUUID'], muted=False)
                self.settle(self.transaction([('mute', first, {'muted': False})], control, signal=False))
                self.command('release-mute', body=lambda command: self.settle(pending))
                self.settle(self.transaction([('mute', first, {'muted': False})], origin='muteEcho', signal=False))
                control = self.control('tones', callUUID=first['callUUID'], digits='12#A')
                self.settle(self.transaction([('tones', first, {'digits': '12#A'})], control))
                self.action('end', first)
            elif self.case == 'provider-reset':
                control = self.control('reset')
                control['response']['result'] = dict(reset=True, provider='synthetic-provider')
                self.native('provider.reset', requestID=control['request']['id'], callUUIDs=[first['callUUID']], cancelledActionIDs=[])
                self.app('system.event', name='providerReset')
                self.calls.clear()
                self.snapshot()
            else: self.action('end', first)
        self.hook()
        self.command('finish')
        self.app('sdk.result', success=True)
        self.app('done')
        return dict(rows=self.rows, engine=self.engine, index=self.index, controls=self.controls,
                    fixture_commands=self.commands, case=self.case, expected_d5=self.expected, profile=PROFILE,
                    launch_receipt=self.launch_receipt)


def first(values, event):
    return next(value for value in values if value['event'] == event)


def native_action(value, kind, event='action.deadline'):
    transaction = next(row for row in value['engine'] if row['event'] == 'transaction.delivered' and gate.NATIVE[kind] in row['kinds'])
    identity = transaction['actionIDs'][transaction['kinds'].index(gate.NATIVE[kind])]
    return next(row for row in value['engine'] if row['event'] == event and row.get('actionID') == identity)


def duplicate_answered_event(value):
    event = first(value['rows'], 'system.event')
    value['rows'].insert(value['rows'].index(event) + 1, deepcopy(event))
    for sequence, row in enumerate(value['rows'], 1): row['sequence'] = sequence


def late_answered_native(value, delay=1001):
    signal = first(value['engine'], 'system.answeredElsewhereSignal')
    report = first(value['engine'], 'report.ended')
    report['t_ms'] = signal['t_ms'] + delay
    next(row for row in value['engine'] if row['event'] == 'call.changed' and row['ended'])['t_ms'] = report['t_ms']


def answered_at_budget(value):
    late_answered_native(value, 1000)
    requested = first(value['rows'], 'system.answeredElsewhereRequested')
    terminal = next(row for row in value['rows'] if row['event'] == 'sdk.snapshot' and
                    any(call['status'] == 'ended' for call in row['conversations']))
    for row in value['rows'][value['rows'].index(terminal):]:
        row['wallTimeMS'] = requested['clockBeforeMS'] + 1000


def move_before(value, row, target):
    """Tamper causal order while retaining a well-formed monotone journal."""
    times = [event['t_ms'] for event in value['engine']]
    value['engine'].remove(row)
    value['engine'].insert(value['engine'].index(target), row)
    for sequence, (event, elapsed) in enumerate(zip(value['engine'], times), 1):
        event.update(sequence=sequence, t_ms=elapsed)
    for binding in value['index']['bindings']:
        binding['reportSequence'] = next(event['sequence'] for event in value['engine']
            if event['event'] == 'report.incoming' and event.get('pushID') == binding['pushID'])


def expired_settlement(value, effective=False, offset_ms=0):
    ready = first(value['rows'], 'system.ready')
    marker = first(value['engine'], 'system.clock')
    deadline = first(value['engine'], 'action.deadline')
    settled = first(value['engine'], 'action.settled')
    elapsed = deadline['expiryMS' if effective else 'deadlineMS'] - ready['wallTimeMS'] + marker['t_ms'] - 1 + offset_ms
    difference = elapsed - settled['t_ms']
    for event in value['engine'][value['engine'].index(settled):]: event['t_ms'] += difference


def handler_deadline(value, kind, shift_ms=0, earlier_advertised=False, extend_advertised=False, advertised_only=False):
    """Tamper all deadline projections together, leaving no mismatch shortcut."""
    handler = next(row for row in value['rows'] if row['event'] == 'system.handler' and row['kind'] == kind)
    transaction = next(row for row in value['engine'] if row['event'] == 'transaction.delivered' and gate.NATIVE[kind] in row['kinds'])
    identity = transaction['actionIDs'][transaction['kinds'].index(gate.NATIVE[kind])]
    advertised = next(row for row in value['engine'] if row['event'] == 'action.deadline' and row['actionID'] == identity)
    old = handler['deadline']
    deadline = gate.timestamp_ms(old) + shift_ms
    margin = 3000 if kind in ('start', 'join') else 1500
    if advertised_only: deadline = advertised['deadlineMS'] - margin
    if earlier_advertised:
        advertised['deadlineMS'] -= 27000
        if not extend_advertised: deadline = advertised['deadlineMS'] - margin
    handler['deadline'] = iso(deadline)
    for row in value['engine']:
        if row['event'] == 'system.handlerEntered' and row['traceSequence'] == handler['sequence']:
            row['deadline'] = handler['deadline']
    for row in value['rows']:
        for call in row.get('conversations', []):
            pending = call.get('pending', {})
            if call['id'] == handler['conversationID'] and pending.get('kind') == kind and pending.get('deadline') == old:
                pending['deadline'] = handler['deadline']


def duplicate_rows(value):
    identity = [control['request']['id'] for control in value['controls'] if control['request']['operation'] == 'push'][1]
    return [row for row in value['engine'] if row.get('pushID') == identity]


def legacy_pushes(value, required=True):
    for row in value['engine']:
        if row['event'] == 'push.received': row['api'] = 'legacy'
        if required and row['event'] in ('push.received', 'push.callbackReturned', 'push.completed'): row['mustReport'] = True


def old_m1_stays_app_only():
    with tempfile.TemporaryDirectory(prefix='sdk-system-legacy-origin-') as temporary:
        root = Path(temporary)
        legacy.fixture_case(root, 'journey', 12345)
        rows = legacy.gate.m0.load(root, 'sdk-m1-journey')
        engine = [json.loads(line) for line in (root / 'sdk-m1-journey.runtime.jsonl').read_text().splitlines()]
        deadlines = legacy.gate.deadline_oracles()[0]
        legacy.gate.case_conformance(rows, engine, 'journey', '27.0', deadlines)
        first(rows, 'm1.handler')['origin'] = 'system'
        try: legacy.gate.case_conformance(rows, engine, 'journey', '27.0', deadlines)
        except gate.EvidenceError as error:
            if 'invalid handler deadline/origin' not in str(error): raise
        else: raise RuntimeError('legacy M1 accepted a system-origin handler')


def manifest_controls():
    checks = []
    identity = dict(sourceCommit='a' * 40, sourceInputsSHA256='b' * 64)

    def write(path, value):
        path.write_text(json.dumps(value, indent=2) + '\n')

    def rehash(root):
        path = root / 'manifest.json'
        value = json.loads(path.read_text())
        value['files'] = {str(path.relative_to(root)): gate.m0.digest(path) for path in root.rglob('*')
                          if path.is_file() and path.name not in ('manifest.json', 'summary.json')}
        write(path, value)

    def change(path, **fields):
        value = json.loads(path.read_text()); value.update(fields); write(path, value)

    def owned_inventory(root, parent):
        owner = json.loads((parent / 'manifest.json').read_text())['simulatorID']
        write(root / 'cleanup-inventory.json', dict(devices={'synthetic': [dict(udid=owner, state='Shutdown')]}))
        change(root / 'cleanup-confirmation.json', inventorySHA256=gate.m0.digest(root / 'cleanup-inventory.json'))
        rehash(root)

    cases = [
        ('manifest-positive', None, None),
        ('manifest-file-hash-dirty', lambda root, parent: (root / 'evidence.json').write_text('changed\n'), 'missing/extra/changed'),
        ('manifest-unlisted-file', lambda root, parent: (root / 'extra.json').write_text('{}\n'), 'missing/extra/changed'),
        ('manifest-missing-file', lambda root, parent: (root / 'evidence.json').unlink(), 'missing/extra/changed'),
        ('manifest-rehashed-wrong-source', lambda root, parent: (change(root / 'manifest.json', sourceCommit='c' * 40), rehash(root)), 'unbound system manifest'),
        ('manifest-parent-bytes-dirty', lambda root, parent: change(parent / 'manifest.json', sourceCommit='c' * 40), 'unbound system manifest'),
        ('manifest-rehashed-live-device-directory', lambda root, parent: (change(root / 'cleanup-confirmation.json', deviceDirectoryAbsent=False), rehash(root)), 'independent cleanup confirmation missing'),
        ('manifest-rehashed-inventory-present', owned_inventory, 'owned simulator remains in cleanup inventory'),
        ('manifest-rehashed-wrong-cleanup-owner', lambda root, parent: (change(root / 'cleanup-confirmation.json', simulatorID=str(uuid.UUID(int=999)).upper()), rehash(root)), 'independent cleanup confirmation missing'),
    ]
    for name, edit, expected in cases:
        with tempfile.TemporaryDirectory(prefix='sdk-system-manifest-controls-') as temporary:
            parent = Path(temporary); root = parent / 'system'; root.mkdir()
            owner = dict(runID='synthetic-manifest-run', simulatorID=str(uuid.UUID(int=100)).upper())
            write(parent / 'manifest.json', dict(**identity, **owner))
            write(root / 'evidence.json', dict(fixtureKind='synthetic'))
            write(root / 'cleanup-inventory.json', dict(devices={'synthetic': []}))
            write(root / 'cleanup-confirmation.json', dict(simulatorID=owner['simulatorID'], inventoryAbsent=True,
                  deviceDirectoryAbsent=True, inventorySHA256=gate.m0.digest(root / 'cleanup-inventory.json')))
            write(root / 'manifest.json', dict(schemaVersion=1, scenario='sdk-system', **identity, **owner,
                  parentManifestSHA256=gate.m0.digest(parent / 'manifest.json')))
            rehash(root)
            if edit: edit(root, parent)
            try: gate.manifest_check(root, parent, identity)
            except gate.EvidenceError as error:
                if expected is None or expected not in str(error): raise RuntimeError(name + ': ' + str(error)) from error
            else:
                if expected is not None: raise RuntimeError(name + ': tampered filesystem evidence passed')
            checks.append(dict(name=name, passed=True, expected=expected or 'synthetic filesystem manifest accepted'))
    return checks


def container_cache_controls():
    import run_sdk_system as runner
    require = gate.require
    checks = []
    with tempfile.TemporaryDirectory(prefix='sdk-system-container-controls-') as temporary:
        root = Path(temporary).resolve()
        container = root / 'container'; container.mkdir()
        package = root / 'package'; package.mkdir()

        def check(name, supplied, accepted):
            journeys = []
            args = SimpleNamespace(package=package, output=root / name, simulator='synthetic-owned-simulator',
                                   run_id='synthetic-run', data_container=supplied)
            class StubJourney:
                def __init__(self, args, directory, case, selected):
                    journeys.append((case, selected))
                def run(self): pass
            with patch.object(runner.m0, 'source_identity', return_value={}), \
                 patch.object(runner, 'Journey', StubJourney), \
                 patch.object(runner.subprocess, 'run', side_effect=AssertionError('container discovery must not issue an RPC')), \
                 patch.object(runner, 'bounded', side_effect=AssertionError('container discovery must use retained evidence')), \
                 patch.object(gate, 'package_check', return_value={}):
                try: runner.run(args)
                except gate.EvidenceError as error:
                    require(not accepted, name + ': unexpected refusal ' + str(error))
                else:
                    require(accepted, name + ': missing refusal')
            require(journeys == ([(case, container) for case in runner.CASES] if accepted else []),
                    name + ': cases did not reuse the same validated path')
            checks.append(dict(name=name, passed=True,
                               expected='one retained container; no RPC' if accepted else 'invalid retained container refused'))

        check('parent-container-no-query', container, True)
        check('missing-parent-container-refused', None, False)
        check('invalid-parent-container-refused', root / 'missing', False)
        check('relative-parent-container-refused', Path('container'), False)
        # Run the real running-control argument builder; the CLI process is inert.
        args = SimpleNamespace(package=package, simulator='synthetic-owned-simulator', run_id='synthetic-run')
        calls = []
        def control(argv, **kwargs):
            require(argv[0] == str(package / 'cksim') and argv.count('--app-container') == 1 and
                    argv[argv.index('--app-container') + 1] == str(container),
                    'running controls must reuse the exact validated container without a new simctl lookup')
            require(kwargs == dict(capture_output=True, timeout=75), 'running control process bounds changed')
            calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, b'{"success":true}', b'')
        with patch.object(runner.subprocess, 'run', side_effect=control):
            selected = runner.app_data_container(args.simulator, container)
            journey = runner.Journey(args, root / 'running-controls', 'end-accept', selected)
            journey.cli('push', '--payload-file', str(root / 'incoming.payload.json'), '--must-report', 'true')
            journey.cli('end-and-accept', 'waiting-call', '--active-call', 'active-call')
        require(len(calls) == 2 and len(journey.controls) == 2, 'running control unexpectedly queried or skipped a process')
        checks.append(dict(name='running-controls-reuse-validated-container', passed=True,
                           expected='exact cached path in both CLI commands; no native query'))
        # Execute only the exact parent dispatch block with a fake python3.
        # No simulator command or the full M0 lifecycle is executed.
        parent = (gate.ROOT / 'discovery/run_sdk_m0.sh').read_text()
        marker = 'PRODUCT_CHECK=sdk-system\nif [[ "${SDK_SYSTEM_ACCEPTANCE:-0}" == 1 ]]; then\n'
        require(parent.count(marker) == 1, 'parent system dispatch seam differs')
        start = parent.index(marker)
        block = parent[start:parent.index('\ncleanup_simulator', start)]
        binary = root / 'bin'; binary.mkdir()
        fake = binary / 'python3'
        fake.write_text('#!/bin/bash\n'
                        'printf \'%s\\0\' "$@" >> "$ARGUMENT_CAPTURE"\n'
                        'if [[ "$*" == *scripts/sim/paths.py* ]]; then printf \'%s\\n\' "$RESOLVED_CONTAINER"; fi\n')
        fake.chmod(0o700)
        for supplied in (True, False):
            capture = root / ('parent-arguments-' + str(supplied))
            env = dict(os.environ, PATH=str(binary) + os.pathsep + os.defpath,
                       ARGUMENT_CAPTURE=str(capture), RESOLVED_CONTAINER=str(container), SDK_SYSTEM_ACCEPTANCE='1',
                       INHERITED_DYLD='/synthetic/inherited.dylib', UDID='synthetic-owned-simulator',
                       RUN_ID='synthetic-run', SDK_SYSTEM_CONTROL_PACKAGE=str(package), OUT=str(root / 'parent-output'))
            env.pop('example_container', None)
            if supplied: env['example_container'] = str(container)
            result = subprocess.run(['/bin/bash', '-eu', '-c', 'limit() { shift; "$@"; }\n' + block], env=env,
                                    capture_output=True, text=True, timeout=5)
            require(result.returncode == 0 and not result.stdout and not result.stderr,
                    'parent container dispatch failed: ' + result.stderr)
            arguments = [part.decode() for part in capture.read_bytes().split(b'\0')[:-1]]
            expected = ['discovery/run_sdk_system.py', '--simulator', env['UDID'], '--run-id', env['RUN_ID'],
                        '--package', str(package), '--output', env['OUT'] + '/system', '--data-container', str(container)]
            if not supplied:
                discovery = arguments[:-len(expected)]
                require(discovery == ['scripts/sim/paths.py', '--receipt', env['OUT'] + '/sdk-m0.receipt.json',
                    '--trace', env['OUT'] + '/sdk-m0.log', '--simulator', env['UDID'], '--run-id', env['RUN_ID'],
                    '--bundle', runner.BUNDLE], 'fallback must bind the completed M0 capture without a container RPC')
                arguments = arguments[-len(expected):]
            require(arguments == expected, 'parent dispatch must always supply the retained container')
            checks.append(dict(name='parent-shell-cached-path' if supplied else 'parent-shell-completed-evidence-fallback',
                               passed=True, expected='parent Bash dispatch always supplies an evidence-bound container'))
    return checks


def cold_staging_controls():
    """Exercise the consumer and actual shipping stage; only its native query is fake."""
    import run_sdk_system as runner
    checks = []
    services = SERVICES.encode()
    cases = (
        ('staged-native-launch', None, 120, None),
        ('staged-query-shares-remaining-budget', None, 3, None),
        ('staged-no-remaining-budget', None, 0, 'checkpoint deadline'),
        ('staged-query-nonzero', 'nonzero', 120, 'Stopped-app query'),
        ('staged-query-timeout', 'timeout', 120, 'Stopped-app query'),
        ('staged-query-timeout-with-zero-status', 'timeout-zero', 120, 'Stopped-app query'),
        ('staged-query-cleanup-uncertain', 'cleanup-uncertain', 120, 'Stopped-app query'),
        ('staged-query-unreaped', 'unreaped', 120, 'Stopped-app query'),
        ('staged-query-diagnostics', 'diagnostics', 120, 'Stopped-app query'),
        ('staged-empty-service-table', 'empty', 120, 'Invalid launchctl service table'),
        ('staged-header-only-service-table', 'header-only', 120, 'Invalid launchctl service table'),
        ('staged-malformed-service-table', 'malformed', 120, 'Invalid launchctl service table'),
        ('staged-running-target', 'running', 120, 'requires a stopped app'),
        ('staged-invalid-payload', 'payload', 120, 'Push payload must be an object'),
        ('staged-oversized-payload', 'oversized', 120, 'Push payload must be an object'),
        ('staged-existing-receipt', 'receipt', 120, 'Launch receipt already exists'),
        ('staged-existing-pending-envelope', 'pending', 120, 'File exists'),
        ('staged-existing-claim', 'claim', 120, 'A push launch claim already exists'),
    )
    for label, kind, remaining, expected_error in cases:
        with tempfile.TemporaryDirectory(prefix='sdk-system-staging-pure-') as temporary:
            root = Path(temporary)
            package = root / 'package'; package.mkdir()
            shutil.copyfile(gate.ROOT / 'Tools/cksim', package / 'cksim')
            container = root / 'container'; container.mkdir()
            args = SimpleNamespace(run_id='synthetic-staging', simulator=str(uuid.UUID(int=1)).upper(), package=package)
            journey = runner.Journey(args, root / 'case', 'push-launch', container)
            payload = journey.root / 'first.payload.json'
            runner.write(payload, dict(incomingCall=dict(eventId='synthetic-event', serverCallId='synthetic-server')))
            receipt = journey.root / 'launch-push.json'
            staged_root = container / 'Documents/.callkit-simulator'
            preserved = {}
            if kind == 'payload': payload.write_text('[]')
            if kind == 'oversized': payload.write_text(json.dumps(dict(value='x' * 5120)))
            if kind in ('receipt', 'pending', 'claim'):
                if kind == 'receipt': path = receipt
                else:
                    staged_root.mkdir(parents=True, mode=0o700)
                    path = staged_root / ('push-launch.json' if kind == 'pending' else 'push-launch.consuming')
                path.write_bytes(b'previous-evidence\n'); preserved[path] = path.read_bytes()
            table = dict(empty=b'', header_only=b'PID\tStatus\tLabel\n',
                         malformed=b'PID\tStatus\tLabel\ninvalid\t0\tlabel\n').get(
                             (kind or '').replace('-', '_'), services)
            if kind == 'running': table += ('123\t0\tUIKitApplication:' + runner.BUNDLE + '[running]\n').encode()
            result = SimpleNamespace(returncode=1 if kind == 'nonzero' else 124 if kind == 'timeout' else 0,
                timed_out=kind in ('timeout', 'timeout-zero'), cleanup_uncertain=kind == 'cleanup-uncertain',
                reaped=kind != 'unreaped', stdout=table,
                stderr=b'synthetic diagnostics\n' if kind == 'diagnostics' else b'')
            inherited = dict(CKSIM_RUN_ID='parent-run', SIMCTL_CHILD_CKSIM_RUN_ID='previous-child-run',
                SIMCTL_CHILD_DYLD_INSERT_LIBRARIES='/synthetic/inherited.dylib',
                SIMCTL_CHILD_SYNTHETIC_MARKER='preserve-me')
            prepared = dict(inherited, SIMCTL_CHILD_CKSIM_RUN_ID=args.run_id,
                SIMCTL_CHILD_SDK_SYSTEM_RUN_ID=args.run_id, SIMCTL_CHILD_SDK_SYSTEM_CASE='push-launch',
                SIMCTL_CHILD_SDK_M0_ACCEPTANCE='0', SIMCTL_CHILD_SDK_M1_CASE='')
            def query(command, timeout, *, env):
                assert command == ['xcrun', 'simctl', 'spawn', args.simulator, 'launchctl', 'list']
                assert timeout == min(60, remaining)
                assert env == dict(prepared, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES='')
                return result
            with patch.object(runner, 'bounded', side_effect=query) as bounded, \
                 patch.object(runner.subprocess, 'run', side_effect=AssertionError('staging issued an unowned native RPC')), \
                 patch.object(runner.subprocess, 'Popen', side_effect=AssertionError('staging launched a child')), \
                 patch.object(runner.os, 'execvpe', side_effect=AssertionError('staging executed the cold CLI launcher')), \
                 patch.dict(os.environ, inherited, clear=True):
                try: command, environment = journey.stage_push(prepared, remaining)
                except (RuntimeError, ValueError, OSError) as error:
                    assert expected_error and expected_error in str(error), (label, str(error))
                else:
                    assert expected_error is None, label + ': unsafe staging was accepted'
                    assert command == ['xcrun', 'simctl', 'launch', '--console', args.simulator, runner.BUNDLE]
                    assert environment == prepared, (label, environment)
                    raw = (staged_root / 'push-launch.json').read_bytes()
                    staged = json.loads(raw); evidence = json.loads(receipt.read_bytes())
                    assert staged['payload'] == json.loads(payload.read_bytes()) and staged['mustReport'] is True
                    assert (staged['runID'], staged['bundleID']) == (args.run_id, runner.BUNDLE)
                    assert evidence['pushID'] == staged['id'] and evidence['envelope'] == staged
                    assert evidence['serviceQuery'] == services.decode()
                    assert evidence['serviceQuerySHA256'] == hashlib.sha256(services).hexdigest()
                    assert evidence['envelopeSHA256'] == hashlib.sha256(raw).hexdigest()
                    assert evidence['runtimeInjectionRequested'] is False and evidence['appServiceAbsent'] is True
                    assert (receipt.stat().st_mode & 0o777, (staged_root / 'push-launch.json').stat().st_mode & 0o777) == (0o600, 0o600)
                assert dict(os.environ) == inherited, label + ': staging mutated the host environment'
            assert bounded.call_count == (1 if remaining > 0 else 0), label + ': native query repeated'
            for path, data in preserved.items(): assert path.read_bytes() == data, label + ': evidence overwritten'
            assert not list(staged_root.glob('.push-launch-*')), label + ': temporary staging file leaked'
            if expected_error:
                assert not receipt.exists() or receipt in preserved, label + ': failure wrote a launch receipt'
                assert not (staged_root / 'push-launch.json').exists() or staged_root / 'push-launch.json' in preserved, \
                    label + ': failure published a launch envelope'
            checks.append(dict(name=label, passed=True, expected=expected_error or 'shared staging returns exact native launch and fixture environment'))
    return checks


def cleanup_transport_controls():
    import run_scenario as supervisor
    from sim import Result, bounded as actual_bounded
    checks = []
    with tempfile.TemporaryDirectory(prefix='sdk-system-stop-transport-') as temporary:
        root = Path(temporary)
        for name, status, stdout, stderr, uncertain in (
            ('success', 0, b'synthetic stopped\n', b'', None),
            ('not-running', 3, b'', __import__('run_sdk_system').NOT_RUNNING.encode(), None),
            ('timeout', 3, b'', b'synthetic diagnostic\n', 'timed_out'),
            ('uncertain', 3, b'', b'synthetic diagnostic\n', 'cleanup_uncertain'),
            ('unreaped', 3, b'', b'synthetic diagnostic\n', 'reaped')):
            command = ['synthetic-stop', name]
            result = Result(command, status, stdout, stderr)
            if uncertain: setattr(result, uncertain, uncertain != 'reaped')
            trace, receipt = root / (name + '.log'), root / (name + '.receipt.json')
            with patch.object(supervisor, 'bounded', return_value=result) as stop:
                supervisor.run([__import__('sys').executable, '-c', 'pass'], command, trace, receipt, 2, {})
            stop.assert_called_once_with(command, 10)
            evidence = json.loads(receipt.read_text())
            assert evidence['cleanupExitCode'] == status
            assert evidence['cleanupStdout'] == stdout.decode() and evidence['cleanupStderr'] == stderr.decode()
            assert ('cleanupError' in evidence) == bool(uncertain)
            checks.append(dict(name='supervisor-stop-' + name, passed=True))
        # Use the actual shared helper in the actual supervisor cleanup path.
        # An isolated host process group must be killed and reaped on timeout.
        pidfile = root / 'stop.pid'
        command = [__import__('sys').executable, '-c',
                   'import os,pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(60)', str(pidfile)]
        def short_bound(argv, timeout):
            assert argv == command and timeout == 10
            return actual_bounded(argv, .25)
        trace, receipt = root / 'real-timeout.log', root / 'real-timeout.receipt.json'
        with patch.object(supervisor, 'bounded', side_effect=short_bound):
            supervisor.run([__import__('sys').executable, '-c', 'pass'], command, trace, receipt, 2, {})
        evidence = json.loads(receipt.read_text())
        assert evidence['cleanupExitCode'] == 124 and 'cleanupError' in evidence
        pid = int(pidfile.read_text())
        try: os.killpg(pid, 0)
        except ProcessLookupError: pass
        else: raise AssertionError('timed-out stop transport group leaked')
        checks.append(dict(name='supervisor-stop-real-timeout-kills-reaps-group', passed=True))
    return checks


def cleanup_controls():
    """Exercise Journey's real finally; all processes, queries and signals are fake."""
    import run_sdk_system as runner
    checks = []
    for label in ('checkpoint-failure-graceful-reap', 'private-group-normal',
                  'timeout-kills-exact-owned-group', 'unknown-group-never-killed',
                  'owner-exited-no-group-kill', 'remaining-group-refuses'):
        with tempfile.TemporaryDirectory(prefix='sdk-system-cleanup-pure-') as temporary:
            root = Path(temporary)
            owner = 7001
            waits = []
            class Process:
                pid = owner
                alive = True
                def poll(self): return None if self.alive else 0
                def wait(self, timeout):
                    waits.append(timeout)
                    if timeout == 25 and label in ('timeout-kills-exact-owned-group', 'unknown-group-never-killed', 'owner-exited-no-group-kill'):
                        if label == 'owner-exited-no-group-kill': self.alive = False
                        raise subprocess.TimeoutExpired('synthetic-supervisor', timeout)
                    self.alive = False
                    return 0
                def terminate(self): raise AssertionError('PID-only supervisor termination bypasses launcher cleanup')
                def kill(self): raise AssertionError('PID-only supervisor kill bypasses launcher cleanup')
            process = Process()
            handlers = {sig: object() for sig in (signal.SIGTERM, signal.SIGINT)}
            previous = handlers.copy()
            def handler(sig, value):
                old = handlers[sig]; handlers[sig] = value; return old
            signals = []
            def group(group_id, value):
                assert group_id == owner and all(value is signal.SIG_IGN for value in handlers.values())
                signals.append((group_id, value))
                if value == 0:
                    if label == 'remaining-group-refuses': return
                    raise ProcessLookupError('synthetic absent group')
                assert value == signal.SIGKILL
                process.alive = False
            container = root / 'container'; container.mkdir()
            args = SimpleNamespace(run_id='synthetic-cleanup', simulator='synthetic-owned', package=root)
            journey = runner.Journey(args, root / 'case', 'decline', container)
            journey.runtime.parent.mkdir(parents=True)
            runner.write(journey.runtime.parent / 'session.json', dict(runID=args.run_id, pid=7003, bundleID=runner.BUNDLE))
            journey.runtime.mkdir()
            journey.journal.write_bytes(b'{"fixtureKind":"synthetic"}\n')
            receipt = journey.root / (journey.name + '.receipt.json')
            runner.write(receipt, dict(fixtureKind='synthetic'))
            def checkpoint(*_):
                if label not in ('private-group-normal', 'remaining-group-refuses'):
                    raise RuntimeError('synthetic checkpoint failure')
                return dict(pid=7003, sequence=1)
            journey.wait = checkpoint
            journey.push = Mock(return_value={}); journey.end = Mock(); journey.command = Mock()
            journey.sim = Mock(side_effect=RuntimeError('synthetic app-stop failure') if label == 'timeout-kills-exact-owned-group' else None)
            with patch.object(runner.subprocess, 'Popen', return_value=process) as spawn, \
                 patch.object(runner.signal, 'signal', side_effect=handler), \
                 patch.object(runner.os, 'getpgid', return_value=owner + (label == 'unknown-group-never-killed')), \
                 patch.object(runner.os, 'getsid', return_value=owner), patch.object(runner.os, 'killpg', side_effect=group):
                try: journey.run()
                except AssertionError: raise
                except Exception as error:
                    assert label != 'private-group-normal'
                    expected = 'ownership is unknown' if label == 'unknown-group-never-killed' else \
                        'group remains or cleanup is unknown' if label == 'remaining-group-refuses' else 'synthetic checkpoint failure'
                    assert expected in str(error), (label, str(error))
                else:
                    assert label == 'private-group-normal'
            assert handlers == previous
            assert spawn.call_args.kwargs.get('start_new_session') is True
            assert spawn.call_args.args[0].count('--inherit-launcher-group') == 1
            assert [item for item in signals if item[1] != 0] == (
                [(owner, signal.SIGKILL)] if label == 'timeout-kills-exact-owned-group' else [])
            assert waits == ([30] if label in ('private-group-normal', 'remaining-group-refuses') else
                             [25, 5] if label in ('timeout-kills-exact-owned-group', 'unknown-group-never-killed', 'owner-exited-no-group-kill') else [25])
            if label == 'timeout-kills-exact-owned-group':
                cleanup = json.loads((journey.root / 'failed-cleanup.json').read_text())
                assert cleanup['forcedGroupKill'] is True and 'app-stop failure' in cleanup['appStopError']
            if label == 'private-group-normal':
                value = json.loads(receipt.read_text())
                assert value['supervisorGroupAbsentAfterStop'] is True
                assert value['journalSHA256'] == gate.m0.digest(journey.root / (journey.name + '.runtime.jsonl'))
                assert json.loads((journey.root / 'index.json').read_text())['supervisorPID'] == owner
            elif label == 'remaining-group-refuses':
                assert 'supervisorGroupAbsentAfterStop' not in json.loads(receipt.read_text())
            else:
                journey.sim.assert_called_once_with('terminate', args.simulator, runner.BUNDLE, timeout=10)
            checks.append(dict(name=label, passed=True, expected='owned cleanup; never native acceptance'))
    return checks


def supervisor_controls():
    receipt = dict(inheritLauncherGroup=True, supervisorPID=7001, supervisorPGID=7001,
                   supervisorSID=7001, launcherPGID=7001, launcherPID=7002, appPID=7003,
                   supervisorGroupAbsentAfterStop=True)
    index = dict(supervisorPID=7001)
    checks = []
    def check(name, value, owner=index, cleanup=False, accepted=False):
        try: gate.supervisor_check(value, owner, cleanup)
        except gate.EvidenceError:
            assert not accepted, name
        else:
            assert accepted, name
        checks.append(dict(name=name, passed=True, expected='strict normal private-group binding'))
    check('normal-supervisor-binding', receipt, accepted=True)
    for key in ('inheritLauncherGroup', 'supervisorPID', 'supervisorPGID', 'supervisorSID',
                'launcherPGID', 'supervisorGroupAbsentAfterStop'):
        value = receipt.copy(); value.pop(key)
        check('missing-' + key, value)
    check('wrong-supervisor-owner', receipt, dict(supervisorPID=7999))
    check('boolean-supervisor-owner', receipt, dict(supervisorPID=True))
    check('wrong-launcher-group', dict(receipt, launcherPGID=7999))
    check('boolean-launcher-group', dict(receipt, launcherPGID=True))
    check('supervisor-app-collision', dict(receipt, appPID=7001))
    check('remaining-supervisor-group', dict(receipt, supervisorGroupAbsentAfterStop=False))
    check('failure-cleanup-cannot-qualify', receipt, cleanup=True)
    return checks


def readiness_controls():
    """Run real startup waits with delayed console rows; no child or signal is real."""
    import run_sdk_system as runner
    checks = []
    class ReachedReady(Exception): pass
    cases = (
        ('push-delayed-ready', 'push-launch', 32, None, 'ready', 32, 0),
        ('direct-delayed-ready', 'decline', 32, None, 'ready', 32, 0),
        ('direct-never-ready', 'decline', None, None, 'deadline', 120, 0),
        ('push-never-ready', 'push-launch', None, None, 'deadline', 120, 0),
        ('push-ready-beyond-budget', 'push-launch', 121, None, 'deadline', 120, 0),
        ('push-supervisor-exit', 'push-launch', None, 10, 'exited', 10, 0),
        ('push-staging-and-readiness-share-budget', 'push-launch', 32, None, 'ready', 32, 30),
        ('push-staging-does-not-extend-deadline', 'push-launch', None, None, 'deadline', 120, 60),
    )
    for label, case, ready_at, exit_at, expected, elapsed, stage_seconds in cases:
        with tempfile.TemporaryDirectory(prefix='sdk-system-readiness-pure-') as temporary:
            root = Path(temporary); clock = [0.0]; owner = 7101
            class Process:
                pid = owner
                reaped = False
                def poll(self):
                    return 0 if self.reaped or (exit_at is not None and clock[0] >= exit_at) else None
                def wait(self, timeout):
                    assert timeout == 25
                    self.reaped = True
                    return 0
            process = Process()
            container = root / 'container'; container.mkdir()
            shutil.copyfile(gate.ROOT / 'Tools/cksim', root / 'cksim')
            args = SimpleNamespace(run_id='synthetic-readiness', simulator='synthetic-owned', package=root)
            journey = runner.Journey(args, root / 'case', case, container)
            journey.runtime.parent.mkdir(parents=True, mode=0o700)
            runner.write(journey.runtime.parent / 'session.json',
                         dict(runID=args.run_id, pid=7103, bundleID=runner.BUNDLE))
            def tick(seconds):
                clock[0] = round(clock[0] + seconds, 3)
                if ready_at is not None and clock[0] >= ready_at and not journey.trace.exists():
                    journey.trace.write_text('PROBE ' + json.dumps(dict(event='system.ready', pid=7103)) + '\n')
            def reached(role, push_id):
                evidence = json.loads((journey.root / 'launch-push.json').read_text())
                assert role == 'first' and push_id == evidence['pushID']
                assert evidence['envelope']['payload']['incomingCall']['caller'] == dict(
                    handleType='generic', value='cold-fixture', displayName='cold-fixture'), 'cold delivery lost the typed calling address'
                raise ReachedReady()
            journey.bind = Mock(side_effect=reached)
            journey.push = Mock(side_effect=ReachedReady())
            journey.sim = Mock()
            def group_absent(group, value):
                assert (group, value) == (owner, 0)
                raise ProcessLookupError('synthetic absent group')
            def query(command, timeout, *, env):
                assert case == 'push-launch'
                assert command == ['xcrun', 'simctl', 'spawn', args.simulator, 'launchctl', 'list']
                assert timeout == 60 and env['SIMCTL_CHILD_DYLD_INSERT_LIBRARIES'] == ''
                assert env['SIMCTL_CHILD_SDK_SYSTEM_CASE'] == case
                tick(stage_seconds)
                return SimpleNamespace(returncode=0, stdout=SERVICES.encode(), stderr=b'',
                                       timed_out=False, cleanup_uncertain=False, reaped=True)
            with patch.object(runner.subprocess, 'Popen', return_value=process) as spawn, \
                 patch.object(runner.subprocess, 'run', side_effect=AssertionError('unexpected native command')), \
                 patch.object(runner, 'bounded', side_effect=query) as bounded, \
                 patch.object(runner.time, 'monotonic', side_effect=lambda: clock[0]), \
                 patch.object(runner.time, 'sleep', side_effect=tick), \
                 patch.object(runner.signal, 'signal'), \
                 patch.object(runner.os, 'killpg', side_effect=group_absent):
                try: journey.run()
                except ReachedReady:
                    outcome = 'ready'
                except RuntimeError as error:
                    if str(error) == case + ': checkpoint deadline': outcome = 'deadline'
                    elif str(error) == 'system supervisor exited before checkpoint': outcome = 'exited'
                    else: raise
                else: raise AssertionError(label + ': startup unexpectedly completed the native journey')
            assert outcome == expected, (label, 'expected ' + expected, outcome, clock[0])
            assert clock[0] == elapsed, (label, 'startup bound changed', clock[0], elapsed)
            command = spawn.call_args.args[0]
            assert float(command[command.index('--timeout') + 1]) == 120 - stage_seconds
            assert spawn.call_args.kwargs['start_new_session'] is True
            assert command[command.index('--launch-command') + 1:] == [
                'xcrun', 'simctl', 'launch', '--console', args.simulator, runner.BUNDLE]
            assert command[command.index('--terminate-command') + 1:command.index('--launch-command')] == [
                'xcrun', 'simctl', 'terminate', args.simulator, runner.BUNDLE]
            environment = spawn.call_args.kwargs['env']
            assert environment['SIMCTL_CHILD_SDK_SYSTEM_CASE'] == case
            assert environment['SIMCTL_CHILD_SDK_SYSTEM_RUN_ID'] == args.run_id
            assert environment['SIMCTL_CHILD_CKSIM_RUN_ID'] == args.run_id
            assert environment['SIMCTL_CHILD_SDK_M0_ACCEPTANCE'] == '0'
            assert environment['SIMCTL_CHILD_SDK_M1_CASE'] == ''
            assert bounded.call_count == (1 if case == 'push-launch' else 0)
            if expected == 'ready':
                if case == 'push-launch':
                    journey.bind.assert_called_once_with('first', json.loads((journey.root / 'launch-push.json').read_text())['pushID'])
                    journey.push.assert_not_called()
                else:
                    journey.push.assert_called_once_with('first')
                    journey.bind.assert_not_called()
                assert journey.pid == 7103
            else:
                journey.bind.assert_not_called(); journey.push.assert_not_called()
            checks.append(dict(name=label, passed=True,
                               expected='bounded startup only; real Journey wait and console-row parsing'))
    return checks


def startup_recovery_controls(selected=None):
    """Exercise the startup driver; simulated console children never run simctl."""
    import run_sdk_system as runner
    checks = []
    cases = [('preapp-rejection-recovered-once', None)]
    cases += [(name, dict(receipt={field: value})) for name, field, value in (
        ('preapp-launcher-exit-not-three', 'launchExitCode', 0),
        ('preapp-precleanup-exit-not-three', 'launchExitCodeBeforeCleanup', 0),
        ('preapp-precleanup-exit-unknown', 'launchExitCodeBeforeCleanup', None),
        ('preapp-cleanup-stopped-app', 'cleanupExitCode', 0),
        ('preapp-cleanup-exit-unknown', 'cleanupExitCode', None),
        ('preapp-cleanup-timeout', 'cleanupError', 'synthetic termination timeout'),
        ('preapp-cleanup-stderr-unknown', 'cleanupStderr', 'synthetic unknown refusal'),
        ('preapp-cleanup-stdout-present', 'cleanupStdout', 'synthetic fresh process'),
        ('preapp-fresh-app-pid', 'appPID', 7203),
        ('preapp-fresh-launcher-pid', 'launcherAppPID', 7203),
        ('preapp-fresh-app-entry', 'appEntryObserved', True),
        ('preapp-fresh-probe-receipt', 'lastProbeEvent', 'runtime.installed'),
        ('preapp-completed-journey', 'completed', True),
        ('preapp-assertion-failure', 'error', 'synthetic journey assertion'),
        ('preapp-wrong-bundle', 'bundleID', 'synthetic.other.bundle'),
        ('preapp-wrong-run', 'runID', 'synthetic-other-run'),
        ('preapp-wrong-supervisor-owner', 'supervisorPID', 9999),
    )]
    cases += [(name, dict(kind=kind)) for name, kind in (
        ('preapp-missing-eof', 'missing-eof'),
        ('preapp-malformed-receipt', 'malformed-receipt'),
        ('preapp-pid-header', 'pid-header'),
        ('preapp-malformed-probe', 'malformed-probe'),
        ('preapp-valid-probe', 'valid-probe'),
        ('preapp-session-changed', 'session-changed'),
        ('preapp-journal-changed', 'journal-changed'),
        ('preapp-bound-conversation', 'bindings'),
        ('preapp-control-issued', 'controls'),
        ('preapp-fixture-command-issued', 'commands'),
        ('preapp-bound-app-pid', 'pid'),
        ('preapp-push-launch-never-replayed', 'push-launch'),
        ('preapp-live-supervisor-group', 'live-group'),
        ('preapp-unknown-supervisor-group', 'unknown-group'),
        ('preapp-aggregate-budget-spent', 'deadline'),
        ('preapp-second-rejection-is-terminal', 'second-failure'),
        ('preapp-second-startup-shares-deadline', 'second-deadline'),
        ('preapp-late-session-changed', 'late-session-changed'),
        ('preapp-late-journal-changed', 'late-journal-changed'),
        ('preapp-late-probe', 'late-probe'),
        ('preapp-late-receipt-pid', 'late-receipt-pid'),
        ('preapp-late-control', 'late-control'),
        ('preapp-deadline-during-guard', 'deadline-during-guard'),
    )]
    for label, change in cases:
        if selected is not None and label not in selected: continue
        with tempfile.TemporaryDirectory(prefix='sdk-system-preapp-pure-') as temporary:
            root = Path(temporary); clock = [0.0]; launched = []
            container = root / 'container'; container.mkdir()
            args = SimpleNamespace(run_id='synthetic-preapp', simulator='synthetic-owned', package=root)
            kind = (change or {}).get('kind')
            journey = runner.Journey(args, root / 'case', 'push-launch' if kind == 'push-launch' else 'decline', container)
            journey.runtime.mkdir(parents=True)
            session = journey.runtime.parent / 'session.json'
            session.write_bytes(b'{"fixtureKind":"previous-case-session"}\n')
            journey.journal.write_bytes(b'{"fixtureKind":"previous-case-journal"}\n')
            receipt_path = journey.root / (journey.name + '.receipt.json')
            ready = dict(event='system.ready', pid=7203)
            first_files = {}
            command = ['python3', str(runner.ROOT / 'discovery/run_scenario.py'),
                '--console-launcher-stop', '--inherit-launcher-group', '--timeout', '120',
                '--output', str(journey.trace), '--receipt', str(receipt_path),
                '--run-id', args.run_id, '--simulator-id', args.simulator, '--scenario', journey.name,
                '--bundle-id', runner.BUNDLE, '--terminate-command', 'xcrun', 'simctl', 'terminate',
                args.simulator, runner.BUNDLE, '--launch-command', 'xcrun', 'simctl', 'launch',
                '--console', args.simulator, runner.BUNDLE]
            journey.stage_push = Mock(return_value=(command[command.index('--launch-command') + 1:], {}))
            class Process:
                def __init__(self, attempt): self.pid, self.attempt = 7200 + attempt, attempt
                def poll(self): return 1 if self.attempt == 1 or kind == 'second-failure' else None
                def wait(self, timeout): return 1
            def spawn(argv, **kwargs):
                captured = json.loads((journey.root / 'prelaunch-baseline.json').read_text())
                assert (captured['case'], captured['scenario'], captured['runID'], captured['simulatorID']) == (
                    journey.case, journey.name, args.run_id, args.simulator)
                expected_raw = (b'{"fixtureKind":"previous-case-session"}\n', b'{"fixtureKind":"previous-case-journal"}\n')
                assert captured['files'] == [dict(kind=kind, path=str(path), present=True,
                    bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())
                    for kind, path, raw in zip(('session', 'journal'), (session, journey.journal), expected_raw)]
                attempt = len(launched) + 1
                launched.append((list(argv), kwargs))
                assert kwargs['start_new_session'] is True
                assert len(launched) <= 2, 'startup recovery launched more than twice'
                process = Process(attempt)
                if attempt == 1 or kind == 'second-failure':
                    clock[0] += 120 if kind == 'deadline' else .5
                    trace = (
                        'An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=3):\n'
                        'Simulator device failed to launch dev.iosvoipsdk.example.\nNo such process\n'
                        'Underlying error (domain=NSPOSIXErrorDomain, code=3):\n'
                        '\tApplication launch for \'dev.iosvoipsdk.example\' did not return a process handle nor launch error.\n'
                        '\tNo such process\n').encode()
                    value = dict(schemaVersion=2, completed=False, success=False,
                        runID=args.run_id, simulatorID=args.simulator, scenario=journey.name, bundleID=runner.BUNDLE,
                        inheritLauncherGroup=True, supervisorPID=process.pid, supervisorPGID=process.pid,
                        supervisorSID=process.pid, launcherPID=7300 + attempt, launcherPGID=process.pid,
                        consoleTransport='host-pty', stdoutEOFSeconds=.25, elapsedSeconds=.5,
                        launchExitCodeBeforeCleanup=3, launchExitCode=3, cleanupExitCode=3,
                        cleanupStdout='', cleanupStderr=(
                            'An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=3):\n'
                            'Simulator device failed to terminate dev.iosvoipsdk.example.\n'
                            'found nothing to terminate\n'
                            'Underlying error (domain=NSPOSIXErrorDomain, code=3):\n'
                            '\tThe request to terminate "dev.iosvoipsdk.example" failed. found nothing to terminate\n'
                            '\tfound nothing to terminate\n'),
                        error='launcher exited before terminal done event',
                        identityError='require one launcher app PID acknowledgement; got 0')
                    value.update((change or {}).get('receipt', {}))
                    if kind == 'missing-eof': value.pop('stdoutEOFSeconds')
                    if kind == 'pid-header': trace += b'dev.iosvoipsdk.example: 7203\n'
                    if kind == 'malformed-probe': trace += b'PROBE {malformed\n'
                    if kind == 'valid-probe': trace += b'PROBE {"event":"app.entry"}\n'
                    if kind == 'session-changed': session.write_bytes(b'{"fixtureKind":"fresh-session"}\n')
                    if kind == 'journal-changed': journey.journal.write_bytes(b'{"event":"runtime.installed","pid":7203}\n')
                    if kind in ('bindings', 'controls', 'commands'): getattr(journey, kind).append('synthetic fresh journey evidence')
                    if kind == 'pid': journey.pid = 7203
                    journey.trace.write_bytes(trace)
                    value['traceSHA256'] = hashlib.sha256(trace).hexdigest()
                    receipt_path.write_text('{malformed\n' if kind == 'malformed-receipt' else json.dumps(value) + '\n')
                    kwargs['stdout'].write(b'synthetic first supervisor diagnostic\n')
                    kwargs['stdout'].flush()
                    if attempt == 1:
                        first_files.update({path.name: path.read_bytes() for path in
                            (journey.trace, receipt_path, journey.root / 'supervisor.log')})
                elif kind != 'second-deadline':
                    journey.trace.write_text('PROBE ' + json.dumps(ready) + '\n')
                return process
            def group_absent(owner, value):
                assert (owner, value) == (7201, 0), 'startup probed an unowned process group'
                if kind == 'live-group': return
                if kind == 'unknown-group': raise PermissionError('synthetic group ownership unknown')
                if kind == 'late-session-changed': session.write_bytes(b'{"fixtureKind":"late-fresh-session"}\n')
                if kind == 'late-journal-changed': journey.journal.write_bytes(b'{"event":"runtime.installed","pid":7203}\n')
                if kind == 'late-probe':
                    journey.trace.write_bytes(journey.trace.read_bytes() + b'PROBE {"event":"app.entry"}\n')
                    first_files[journey.trace.name] = journey.trace.read_bytes()
                if kind == 'late-receipt-pid':
                    receipt = json.loads(receipt_path.read_text()); receipt['appPID'] = 7203
                    receipt_path.write_text(json.dumps(receipt) + '\n')
                    first_files[receipt_path.name] = receipt_path.read_bytes()
                if kind == 'late-control': journey.controls.append('synthetic late fresh control')
                raise ProcessLookupError('synthetic first supervisor group absent')
            read_bytes = Path.read_bytes
            def read_with_guard_delay(path):
                value = read_bytes(path)
                if kind == 'deadline-during-guard' and path.parent.name == 'preapp-attempt-1' and path.name == receipt_path.name:
                    clock[0] = 120
                return value
            with patch.object(runner.subprocess, 'Popen', side_effect=spawn), \
                 patch.object(runner.subprocess, 'run', side_effect=AssertionError('unexpected native command')), \
                 patch.object(runner.time, 'monotonic', side_effect=lambda: clock[0]), \
                 patch.object(runner.time, 'sleep', side_effect=lambda seconds: clock.__setitem__(0, round(clock[0] + seconds, 3))), \
                 patch.object(runner.os, 'killpg', side_effect=group_absent), \
                 patch.object(Path, 'read_bytes', new=read_with_guard_delay):
                try: result = journey.start(command, {})
                except (RuntimeError, gate.EvidenceError):
                    assert change is not None, label + ': exact pre-app rejection was not recovered'
                else:
                    assert change is None and result == ready and journey.process.pid == 7202, label + ': unsafe recovery passed'
            expected_attempts = 2 if change is None or kind in ('second-failure', 'second-deadline') else 1
            assert len(launched) == expected_attempts, label + ': refusal launched another supervisor'
            assert float(launched[0][0][launched[0][0].index('--timeout') + 1]) == 120
            archive = journey.root / 'preapp-attempt-1'
            if expected_attempts == 2 or (kind or '').startswith('late-') or kind == 'deadline-during-guard':
                if expected_attempts == 2:
                    assert float(launched[1][0][launched[1][0].index('--timeout') + 1]) == 119.5
                for name, content in first_files.items(): assert (archive / name).read_bytes() == content, name
            else:
                assert not archive.exists(), label + ': refused attempt was moved'
                for name, content in first_files.items(): assert (journey.root / name).read_bytes() == content, name
            assert clock[0] == (120 if kind in ('deadline', 'second-deadline', 'deadline-during-guard') else
                                1 if kind == 'second-failure' else .5), label
            assert journey.stage_push.call_count == (1 if kind == 'push-launch' else 0), label + ': cold stage repeated'
            checks.append(dict(name=label, passed=True,
                expected='one bounded pre-app recovery; original attempt retained' if change is None else
                         'fresh, partial, unknown or second-attempt evidence never triggers another launch'))
    return checks


def startup_cleanup_diagnostic_control():
    """Real host console children prove cleanup diagnostics reach the receipt."""
    import sys
    import run_scenario as scenario
    launch_stderr = (
        'An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=3):\n'
        'Simulator device failed to launch dev.iosvoipsdk.example.\nNo such process\n'
        'Underlying error (domain=NSPOSIXErrorDomain, code=3):\n'
        '\tApplication launch for \'dev.iosvoipsdk.example\' did not return a process handle nor launch error.\n'
        '\tNo such process\n').encode()
    stop_stderr = (
        'An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=3):\n'
        'Simulator device failed to terminate dev.iosvoipsdk.example.\nfound nothing to terminate\n'
        'Underlying error (domain=NSPOSIXErrorDomain, code=3):\n'
        '\tThe request to terminate "dev.iosvoipsdk.example" failed. found nothing to terminate\n'
        '\tfound nothing to terminate\n')
    def child(stderr):
        return [sys.executable, '-c', 'import os; os.write(2, ' + repr(stderr) + '); raise SystemExit(3)']
    with tempfile.TemporaryDirectory(prefix='sdk-system-preapp-host-') as temporary:
        root = Path(temporary); output, receipt = root / 'trace.log', root / 'receipt.json'
        status = scenario.run(child(launch_stderr), child(stop_stderr.encode()), output, receipt, 2,
                              dict(bundleID='dev.iosvoipsdk.example'), console_launcher_stop=True)
        value = json.loads(receipt.read_text())
        assert status == 1 and value['success'] is False and value['completed'] is False
        assert value['launchExitCodeBeforeCleanup'] == value['launchExitCode'] == value['cleanupExitCode'] == 3
        assert value['cleanupStdout'] == '' and value['cleanupStderr'] == stop_stderr
        assert 0 <= value['stdoutEOFSeconds'] < 2
        assert output.read_bytes() == launch_stderr
        assert value['traceSHA256'] == hashlib.sha256(launch_stderr).hexdigest()
        assert value['identityError'] == 'require one launcher app PID acknowledgement; got 0'
    return [dict(name='preapp-real-host-cleanup-diagnostics', passed=True,
                 expected='exact EOF/exit3/cleanup stderr retained from real host children; no native launch')]


def controls():
    expected = gate.d5_compositions([json.loads(line) for line in (gate.ROOT / gate.D5).read_text().splitlines()])
    fixtures = {case: Fixture(case, expected).build() for case in gate.CASES}
    checks = []

    def check(name, case, edit=None, error=None, report_start_ms=None):
        value = (Fixture(case, expected, report_start_ms).build() if report_start_ms is not None
                 else deepcopy(fixtures[case]))
        if edit: edit(value)
        try:
            result = gate.validate_case(**value)
        except gate.EvidenceError as rejected:
            if error is None or error not in str(rejected):
                raise RuntimeError(name + ': unexpected rejection: ' + str(rejected)) from rejected
        else:
            if error is not None: raise RuntimeError(name + ': tampered evidence passed')
            if result.get('passed') is not True: raise RuntimeError(name + ': positive fixture failed')
        checks.append(dict(name=name, passed=True, expected=error or 'synthetic logical case accepted'))

    for case in gate.CASES: check('positive-' + case, case)
    check('answered-at-budget', 'answered-elsewhere', answered_at_budget)
    check('answered-native-beyond-budget', 'answered-elsewhere', late_answered_native,
          'answered-elsewhere native dismissal exceeded 1000 ms')
    check('answered-wrong-native-reason', 'answered-elsewhere', lambda value: first(value['engine'], 'report.ended').update(reason=2),
          'answered-elsewhere native dismissal differs')
    check('answered-wrong-native-call', 'answered-elsewhere', lambda value: first(value['engine'], 'report.ended').update(callUUID=str(uuid.UUID(int=999)).upper()),
          'answered-elsewhere native dismissal differs')
    check('answered-native-still-ringing', 'answered-elsewhere', lambda value: next(row for row in value['engine'] if row['event'] == 'call.changed' and row['ended']).update(ringing=True),
          'answered-elsewhere native dismissal differs')
    check('answered-wrong-signal-id', 'answered-elsewhere', lambda value: first(value['engine'], 'system.answeredElsewhereSignal').update(eventId='other-event'),
          'answered-elsewhere signal identity/order differs')
    check('answered-wrong-signal-sequence', 'answered-elsewhere', lambda value: first(value['engine'], 'system.answeredElsewhereSignal').update(traceSequence=1),
          'answered-elsewhere signal identity/order differs')
    check('answered-command-wrong-server', 'answered-elsewhere', lambda value: value['fixture_commands'][0].update(serverCallId='other-server'),
          'answered-elsewhere command targets another call')
    check('answered-rejected-host-signal', 'answered-elsewhere', lambda value: first(value['rows'], 'system.answeredElsewhereAccepted').update(accepted=False),
          'answered-elsewhere signal identity/order differs')
    check('answered-clock-unbounded', 'answered-elsewhere', lambda value: first(value['rows'], 'system.answeredElsewhereRequested').update(
          clockBeforeMS=first(value['rows'], 'system.answeredElsewhereRequested')['wallTimeMS'] - 26),
          'unbounded answered-elsewhere signal clock')
    check('answered-event-wrong-call', 'answered-elsewhere', lambda value: first(value['rows'], 'system.event').update(conversationID=str(uuid.UUID(int=999)).upper()),
          'unbound answered-elsewhere SDK event')
    check('answered-event-wrong-server', 'answered-elsewhere', lambda value: first(value['rows'], 'system.event').update(serverCallId='other-server'),
          'answered-elsewhere terminal projection/event differs')
    check('answered-event-wrong-event', 'answered-elsewhere', lambda value: first(value['rows'], 'system.event').update(eventId='other-event'),
          'answered-elsewhere terminal projection/event differs')
    check('answered-event-late', 'answered-elsewhere', lambda value: first(value['rows'], 'system.event').update(
          wallTimeMS=first(value['rows'], 'system.answeredElsewhereRequested')['clockBeforeMS'] + 1001),
          'answered-elsewhere projection/event/hook exceeded 1000 ms')
    check('answered-event-duplicate', 'answered-elsewhere', duplicate_answered_event, 'require one system.event')
    check('answered-wrong-projected-reason', 'answered-elsewhere', lambda value: [call.update(endedReason='remoteEnded')
          for row in value['rows'] if row['event'] == 'sdk.snapshot' for call in row['conversations'] if call['status'] == 'ended'],
          'answered-elsewhere terminal projection/event differs')
    check('answered-empty-hook-late', 'answered-elsewhere', lambda value: [row for row in value['rows'] if row['event'] == 'system.hook'][-1].update(
          wallTimeMS=first(value['rows'], 'system.answeredElsewhereRequested')['clockBeforeMS'] + 1001),
          'answered-elsewhere projection/event/hook exceeded 1000 ms')
    for delay in (0, 499):
        check('cold-report-start-' + str(delay), 'push-launch', report_start_ms=delay)
    check('cold-report-start-at-budget', 'push-launch', error='cold PushKit report start exceeded 500 ms', report_start_ms=500)
    check('warm-report-start-outside-cold-budget', 'answer-end', report_start_ms=500)
    check('removed-shared-owner', 'answer-end', lambda value: first(value['rows'], 'sdk.managerCreated').update(owner='ConversationClient.shared'), 'SDK journey failed')
    check('reset-event-fabricated-conversation', 'provider-reset', lambda value: first(value['rows'], 'system.event').update(
        conversationID=value['index']['bindings'][0]['conversationID']), 'invalid global SDK event context')
    check('audio-event-fabricated-conversation', 'provider-reset', lambda value: first(value['rows'], 'system.event').update(
        name='audioActivated', conversationID=value['index']['bindings'][0]['conversationID']), 'invalid global SDK event context')
    check('positive-legacy-duplicate-required', 'mute-echo', legacy_pushes)
    check('system-handler-as-app', 'answer-end', lambda value: first(value['rows'], 'system.handler').update(origin='app'), 'handler origin/kind/role unbound')
    check('native-origin-as-app', 'answer-end', lambda value: first(value['engine'], 'transaction.delivered').update(origin='application'), 'system native action binding/origin differs')
    check('control-nonce-mismatch', 'answer-end', lambda value: value['controls'][1]['response'].update(id=str(uuid.UUID(int=999)).upper()), 'control identity differs')
    check('D5-order', 'hold-accept', lambda value: next(row for row in value['engine'] if row['event'] == 'transaction.delivered' and len(row['kinds']) == 2)['kinds'].reverse(), 'native composition/parameters differ')
    check('D5-wrong-target', 'end-accept', lambda value: next(row for row in value['engine'] if row['event'] == 'transaction.delivered' and len(row['kinds']) == 2)['callUUIDs'].reverse(), 'native composition/parameters differ')
    check('D5-hold-value', 'hold-accept', lambda value: next(row for row in value['engine'] if row['event'] == 'transaction.delivered' and len(row['kinds']) == 2)['parameters'][0].update(held=False), 'native composition/parameters differ')
    check('D5-held-projection', 'hold-accept', lambda value: [call.update(status='connected') for row in value['rows'] if row['event'] == 'sdk.snapshot' for call in row['conversations'] if call['status'] == 'held'], 'D5 projection did not compose')
    check('D5-held-hook', 'hold-accept', lambda value: [row.update(status='connected') for row in value['rows'] if row['event'] == 'system.hook' and row.get('status') == 'held'], 'held first-call hook missing')
    check('mute-projection-stays-false', 'mute-echo', lambda value: [call.update(isMuted=False) for row in value['rows'] if row['event'] == 'sdk.snapshot' for call in row['conversations']], 'mute projection/hook did not round trip')
    check('mute-hook-stays-false', 'mute-echo', lambda value: [row.update(muted=False) for row in value['rows'] if row['event'] == 'system.hook'], 'mute projection/hook did not round trip')
    check('decline-connected', 'decline', lambda value: next(row for row in value['rows'] if row['event'] == 'sdk.snapshot' and row['conversations'])['conversations'][0].update(status='connected'), 'declined call connected')
    check('native-action-id', 'answer-end', lambda value: value['controls'][1]['response']['result'].update(actionIDs=[str(uuid.UUID(int=999)).upper()]), 'system native action binding/origin differs')
    for kind, case in (('join', 'answer-end'), ('hold', 'hold-accept'), ('end', 'decline')):
        check('old-30-expiry-' + kind, case,
              lambda value, kind=kind: native_action(value, kind).update(expirySeconds=30), 'unsettled/expired/wrong native deadline')
    for kind in ('mute', 'tones'):
        check('non-target-expiry-' + kind, 'mute-echo',
              lambda value, kind=kind: native_action(value, kind).update(expirySeconds=64), 'unsettled/expired/wrong native deadline')
    check('arbitrary-join-expiry', 'answer-end', lambda value: native_action(value, 'join').update(expirySeconds=65), 'unsettled/expired/wrong native deadline')
    check('altered-advertised-deadline', 'answer-end', lambda value: native_action(value, 'join').update(deadlineSeconds=64), 'unsettled/expired/wrong native deadline')
    check('fulfilled-but-expired', 'answer-end', lambda value: native_action(value, 'join', 'action.settled').update(expired=True), 'unsettled/expired/wrong native deadline')
    for field in ('issuedAtMS', 'expiryMS'):
        check('native-' + field + '-missing', 'answer-end',
              lambda value, field=field: native_action(value, 'join').pop(field), 'unsettled/expired/wrong native deadline')
        for invalid in (True, '0', None):
            check('native-' + field + '-type-' + str(invalid), 'answer-end',
                  lambda value, field=field, invalid=invalid: native_action(value, 'join').update({field: invalid}),
                  'unsettled/expired/wrong native deadline')
        check('native-' + field + '-mismatch-1ms', 'answer-end',
              lambda value, field=field: native_action(value, 'join').update({field: native_action(value, 'join')[field] + 1}),
              'unsettled/expired/wrong native deadline')
    check('settlement-at-expiry', 'answer-end', expired_settlement, 'native settlement reached platform expiry')
    check('settlement-at-effective-end-expiry', 'decline', lambda value: expired_settlement(value, effective=True), 'native settlement reached platform expiry')
    check('settlement-after-reported-expiry-1ms', 'answer-end', lambda value: expired_settlement(value, offset_ms=1), 'native settlement reached platform expiry')
    check('settlement-after-effective-end-expiry-1ms', 'decline', lambda value: expired_settlement(value, effective=True, offset_ms=1), 'native settlement reached platform expiry')
    check('effective-margin-absent', 'answer-end', lambda value: first(value['rows'], 'system.handler').update(deadline=iso(first(value['engine'], 'action.deadline')['deadlineMS'])), 'handler deadline differs from selected cap and margin')
    for kind, case in (('hold', 'hold-accept'), ('end', 'answer-end')):
        check('effective-' + kind + '-old-advertised-only', case,
              lambda value, kind=kind: handler_deadline(value, kind, advertised_only=True),
              'handler deadline differs from selected cap and margin')
        for label, shift in (('beyond-delivery-allowance', 253), ('double-margin', -1500), ('no-margin', 1500)):
            check('effective-' + kind + '-' + label, case,
                  lambda value, kind=kind, shift=shift: handler_deadline(value, kind, shift),
                  'handler deadline differs from selected cap and margin')
        check('effective-' + kind + '-delivery-allowance', case,
              lambda value, kind=kind: handler_deadline(value, kind, 250))
        check('effective-' + kind + '-earlier-advertised', case,
              lambda value, kind=kind: handler_deadline(value, kind, earlier_advertised=True))
        check('effective-' + kind + '-earlier-advertised-extended', case,
              lambda value, kind=kind: handler_deadline(value, kind, earlier_advertised=True, extend_advertised=True),
              'handler deadline differs from selected cap and margin')
    check('effective-join-native-wrapper-offset', 'answer-end', lambda value: handler_deadline(value, 'join', 7))
    check('effective-tones-native-wrapper-offset', 'mute-echo', lambda value: handler_deadline(value, 'tones', 2))
    check('effective-join-outside-native-margin', 'answer-end', lambda value: handler_deadline(value, 'join', 502),
          'handler deadline differs from selected cap and margin')
    check('effective-clock-marker-missing', 'answer-end', lambda value: value['engine'].remove(first(value['engine'], 'system.clock')),
          'require one system.clock')
    check('effective-clock-marker-invalid', 'answer-end', lambda value: first(value['engine'], 'system.clock').update(t_ms='invalid'),
          'invalid handler delivery clock')
    check('effective-clock-bound-missing', 'answer-end', lambda value: first(value['rows'], 'system.ready').pop('clockBeforeMS'),
          'unbounded journal clock bridge')
    check('effective-clock-bound-invalid', 'answer-end', lambda value: first(value['rows'], 'system.ready').update(
        clockBeforeMS=first(value['rows'], 'system.ready')['wallTimeMS'] - 26),
          'unbounded journal clock bridge')
    check('pending-effective-deadline', 'answer-end', lambda value: next(row for row in value['rows'] if row['event'] == 'sdk.snapshot' and row['conversations'] and row['conversations'][0].get('pending'))['conversations'][0]['pending'].update(deadline=iso(WALL)), 'handler/pending deadline mismatch')
    check('handler-marker-before-delivery', 'answer-end', lambda value: move_before(value, first(value['engine'], 'system.handlerEntered'), first(value['engine'], 'transaction.delivered')), 'handler/native causal order differs')
    check('handler-marker-deadline', 'answer-end', lambda value: first(value['engine'], 'system.handlerEntered').update(deadline=iso(WALL)), 'handler/native causal order differs')
    check('report-after-callback', 'answer-end', lambda value: move_before(value, first(value['engine'], 'push.callbackReturned'), first(value['engine'], 'report.incoming')), 'incoming wrapper attempt/completion differs')
    check('duplicate-payload-different', 'mute-echo', lambda value: [control for control in value['controls'] if control['request']['operation'] == 'push'][1]['request']['payload'].update(other='different-event'), 'duplicate push was not the same event')
    check('duplicate-report', 'mute-echo', lambda value: value['engine'].append(dict(first(value['engine'], 'report.incoming'))), 'require one report.incoming')
    check('duplicate-report-attempt-missing', 'mute-echo', lambda value: value['engine'].remove(first(duplicate_rows(value), 'report.incoming')), 'incoming report-attempt inventory differs')
    check('duplicate-report-wrong-error', 'mute-echo', lambda value: first(duplicate_rows(value), 'report.completed').update(error=0), 'incoming wrapper attempt/completion differs')
    check('duplicate-report-wrong-call', 'mute-echo', lambda value: [row.update(callUUID=str(uuid.UUID(int=999)).upper()) for row in duplicate_rows(value) if row['event'] in ('report.incoming', 'report.completed')], 'duplicate invitation targeted another call')
    check('duplicate-rings-again', 'mute-echo', lambda value: next(row for row in value['rows'] if row['event'] == 'sdk.snapshot' and row['conversations'] and row['conversations'][0].get('pending', {}).get('kind') == 'mute')['conversations'][0].update(status='ringing'), 'duplicate invitation rang again')
    check('legacy-optional-flag-cannot-suppress-report', 'mute-echo', lambda value: legacy_pushes(value, required=False), 'PushKit delivery/callback receipt differs')
    check('pending-echo-after-app-settlement', 'mute-echo', lambda value: move_before(value,
        next(row for row in value['engine'] if row['event'] == 'action.settled' and row['origin'] == 'application'),
        next(row for row in value['engine'] if row['event'] == 'transaction.delivered' and row['actionIDs'] ==
             next(control['response']['result']['actionIDs'] for control in value['controls'] if control['request']['operation'] == 'mute' and control['request']['muted'] is False))), 'same-value echo was not pending')
    check('pending-reset-wrong-rejection', 'mute-echo', lambda value: first(value['engine'], 'control.rejected').update(requestID=str(uuid.UUID(int=999)).upper()), 'pending reset refusal was not bound')
    check('reset-target', 'provider-reset', lambda value: first(value['engine'], 'provider.reset').update(callUUIDs=[]), 'selected-provider reset did not reach the SDK')
    check('reset-missing-event', 'provider-reset', lambda value: first(value['rows'], 'system.event').update(name='other'), 'unexpected SDK event context')
    check('cold-launched-active-app', 'push-launch', lambda value: value['launch_receipt'].update(appServiceAbsent=False), 'cold launch was not external/stopped/bound')
    active_services = SERVICES + '\n12345\t0\tUIKitApplication:' + gate.BUNDLE + '[synthetic-active]'
    check('cold-rehashed-active-service', 'push-launch', lambda value: value['launch_receipt'].update(
        serviceQuery=active_services, serviceQuerySHA256=hashlib.sha256(active_services.encode()).hexdigest()), 'cold launch app was still running')
    for label, services in (('empty', ''), ('malformed', 'PID\tStatus\tLabel\ninvalid\t0\tlabel\n')):
        check('cold-rehashed-' + label + '-service-table', 'push-launch', lambda value, services=services: value['launch_receipt'].update(
            serviceQuery=services, serviceQuerySHA256=hashlib.sha256(services.encode()).hexdigest()), 'cold launch app was still running')
    check('cold-envelope-hash', 'push-launch', lambda value: first(value['engine'], 'push.launchConsumed').update(envelopeSHA256='0' * 64), 'runtime consumed different launch bytes')
    check('cold-envelope-payload-unhashed', 'push-launch', lambda value: value['launch_receipt']['envelope']['payload'].update(tampered=True), 'cold launch envelope hash differs')
    check('cold-envelope-expiry', 'push-launch', lambda value: value['launch_receipt']['envelope'].update(expiresAtMS=WALL + 30001), 'cold envelope identity/lifetime differs')
    check('cold-pending-as-app', 'push-launch', lambda value: next(row for row in value['rows'] if row['event'] == 'sdk.snapshot' and row['conversations'] and row['conversations'][0].get('pending'))['conversations'][0]['pending'].update(origin='app'), 'cold system answer did not pend without handler')
    check('cold-completion-report-missing', 'push-launch', lambda value: first(value['engine'], 'push.completed').update(reportEntered=False), 'cold PushKit report/callback/completion missing')
    check('cold-incoming-completion-error', 'push-launch', lambda value: first(value['engine'], 'report.completed').update(error=2), 'cold PushKit report/callback/completion missing')
    check('fabricated-connected-before-backend', 'answer-end', lambda value: next(row for row in value['rows'] if row['event'] == 'sdk.snapshot' and row['conversations'] and row['conversations'][0]['status'] == 'connecting' and 'pending' not in row['conversations'][0])['conversations'][0].update(status='connected', hasConnectedAt=True), 'connected state was fabricated')
    check('final-hook-nonempty', 'answer-end', lambda value: [row for row in value['rows'] if row['event'] == 'system.hook'][-1].update(count=1), 'final hook not observed')
    old_m1_stays_app_only()
    checks.append(dict(name='legacy-M1-remains-app-only', passed=True, expected='system-origin legacy handler rejected'))
    gate.cold_push_reference()
    checks.append(dict(name='cold-device-reference', passed=True, expected='entered iOS27 report reference consumed'))
    checks.extend(manifest_controls())
    checks.extend(container_cache_controls())
    checks.extend(cold_staging_controls())
    checks.extend(cleanup_transport_controls())
    checks.extend(cleanup_controls())
    checks.extend(supervisor_controls())
    checks.extend(readiness_controls())
    checks.extend(startup_recovery_controls())
    checks.extend(startup_cleanup_diagnostic_control())
    return checks


if __name__ == '__main__':
    print(json.dumps(dict(success=True, measurement='measured synthetic logical-gate controls only', checks=controls()), indent=2))
