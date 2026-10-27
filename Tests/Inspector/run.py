#!/usr/bin/env python3
"""Tap the separate inspector, then consume its runtime journal and UI screenshots."""
import argparse
from functools import lru_cache
import hashlib
import json
import math
import os
from pathlib import Path
import runpy
import signal
import subprocess
import sys
import time
from types import SimpleNamespace
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Tests/RuntimeEvents'))
from run import capture_diagnostics, fixture_session, latest_runtime, launch_fixture, record_environment, remove_simulators, run

sys.path.insert(0, str(ROOT / 'scripts/sim'))
from inspector_startup import cleanup_operations, locate_probe, supervise_launch

BUNDLE = 'dev.callkitsim.eventfixture'
INSPECTOR = 'dev.callkitsim.inspector'


class ProbeReader:
    """Accept only fresh, process-pinned projections written by the Inspector."""
    def __init__(self, path, nonce, session, diagnostic_path=None, resume_log=None, container=None):
        self.path, self.nonce, self.session = path, nonce, session
        self.diagnostic_path = diagnostic_path
        self.container = container
        self.resume_log, self.resume_raw = resume_log, None
        self.pid = self.started = None
        self.cursor = 0
        self.online = False
        self.reason = 'receipt not published'

    def read(self, resume_after=None):
        try:
            raw = self.path.read_text()
        except FileNotFoundError:
            return None
        if self.diagnostic_path is not None:
            try:
                self.diagnostic_path.write_text(raw)
            except OSError as error:
                print('Cannot save Inspector receipt diagnostic: ' + str(error), file=sys.stderr)
        try:
            value = json.loads(raw)
        except json.JSONDecodeError:
            self.reason = 'Inspector receipt publication is incomplete'
            return None
        if value.get('nonce') != self.nonce:
            if self.pid is not None:
                raise RuntimeError('Inspector nonce changed')
            self.reason = 'receipt nonce does not match this launch'
            return None
        if self.container is not None and (self.path.resolve(strict=True) != self.path or
                value.get('inspectorBundleID') != INSPECTOR or
                value.get('inspectorDataContainer') != str(self.container)):
            raise RuntimeError('Inspector native bundle/container identity changed')
        now = time.time() * 1000
        pid = value['inspectorPID']
        if type(pid) is not int or pid <= 0 or self.pid not in (None, pid):
            raise RuntimeError('Inspector process changed or has invalid identity')
        if self.started not in (None, value['startedWallTimeMS']):
            raise RuntimeError('Inspector startup identity changed')
        self.pid, self.started = pid, value['startedWallTimeMS']
        session = value.get('session')
        if session is None and not self.online:
            self.reason = value.get('error') or 'Inspector has not connected'
            return None
        keys = ('schemaVersion', 'runID', 'pid', 'bundleID', 'profile')
        if not session or any(session.get(key) != self.session[key] for key in keys):
            raise RuntimeError('Inspector target session changed')
        cursor = value['cursor']
        if type(cursor) is not int or cursor < self.cursor:
            raise RuntimeError('Inspector cursor regressed')
        rows = value['timeline']
        if [row['sequence'] for row in rows] != list(range(cursor - len(rows) + 1, cursor + 1)):
            raise RuntimeError('Inspector timeline is inconsistent with its cursor')
        if any(any(row.get(key) != self.session[key] for key in keys[:-1]) for row in rows):
            raise RuntimeError('Inspector timeline identity changed')
        if not -1000 <= now - value['startedWallTimeMS'] <= 25000:
            raise RuntimeError('Inspector background budget expired')
        if resume_after is not None:
            if self.resume_log is not None and raw != self.resume_raw:
                try:
                    with self.resume_log.open('a') as output:
                        output.write(json.dumps(dict(resumeAfterMS=resume_after, receipt=value)) + '\n')
                except OSError as error:
                    print('Cannot save Inspector resume diagnostic: ' + str(error), file=sys.stderr)
                self.resume_raw = raw
            if value['wallTimeMS'] < resume_after or not value['online'] or value.get('error'):
                self.reason = 'Inspector resuming: ' + str(value.get('error') or 'awaiting a new receipt')
                return None
        if not -1000 <= now - value['wallTimeMS'] <= 5000:
            raise RuntimeError('Inspector receipt is stale')
        if self.online and (not value['online'] or value.get('error')):
            raise RuntimeError('Inspector disconnected: ' + str(value.get('error')))
        self.cursor = cursor
        self.online = self.online or value['online']
        self.reason = value.get('error') or f'Inspector has not reached the requested state (cursor {cursor})'
        return value

    def wait(self, predicate, timeout=5, deadline=None, resume_after=None):
        stop = min(time.monotonic() + timeout, deadline if deadline is not None else float('inf'))
        if resume_after is not None:
            self.resume_raw = None
        while time.monotonic() < stop:
            value = self.read(resume_after=resume_after)
            if value is not None and value['online']:
                resume_after = None
            if value is not None and predicate(value):
                return value
            time.sleep(0.05)
        if deadline is not None:
            remaining_budget(deadline)
        raise RuntimeError('Inspector projection timed out: ' + self.reason)


def remaining_budget(deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise RuntimeError('Inspector consumer background budget expired')
    return remaining


def activate_existing(device, bundle, pid, deadline):
    # Foregrounding shares the consumer lifetime, including hosted launch latency.
    output = run('xcrun', 'simctl', 'launch', device, bundle, timeout=remaining_budget(deadline))
    remaining_budget(deadline)
    identities = [line.split(':', 1)[1].strip() for line in output.splitlines() if line.startswith(bundle + ':')]
    if identities != [str(pid)]:
        raise RuntimeError(f'Foreground activation PID changed for {bundle}: expected {pid}, got {output!r}')


def read_runtime_journal(channel, session):
    if json.loads((channel / 'session.json').read_text()) != session:
        raise RuntimeError('Runtime session changed during foreground control')
    data = (channel / session['runID'] / 'events.jsonl').read_bytes()
    complete = data.rsplit(b'\n', 1)[0].split(b'\n') if b'\n' in data else []
    rows = [json.loads(line) for line in complete if line]
    for sequence, row in enumerate(rows, 1):
        if row['sequence'] != sequence or any(row.get(key) != session[key] for key in ('schemaVersion', 'runID', 'pid', 'bundleID', 'profile')):
            raise RuntimeError('Runtime journal identity/order changed')
    return rows


def record_case_baseline(out, channel, session, name):
    """Retain the bound journal bytes before a distinct planned consumer starts."""
    read_runtime_journal(channel, session)
    identity = (channel / 'session.json').read_bytes()
    journal = (channel / session['runID'] / 'events.jsonl').read_bytes()
    if json.loads(identity) != session or (channel / 'session.json').read_bytes() != identity:
        raise RuntimeError('Runtime session changed while recording case baseline')
    (out / 'case-baseline.json').write_text(json.dumps(dict(
        name=name, runID=session['runID'], pid=session['pid'], bundleID=session['bundleID'],
        sessionSHA256=hashlib.sha256(identity).hexdigest(),
        journalSHA256=hashlib.sha256(journal).hexdigest(), journalBytes=len(journal),
        recordedWallTimeMS=int(time.time() * 1000))))


def wait_runtime(predicate, channel, session, deadline, timeout=5):
    stop = min(time.monotonic() + timeout, deadline)
    while time.monotonic() < stop:
        rows = read_runtime_journal(channel, session)
        remaining_budget(deadline)
        if predicate(rows):
            return rows
        time.sleep(0.05)
    remaining_budget(deadline)
    raise RuntimeError('Foreground runtime journal did not reach the required state')


def verify_probe_journal(receipts, rows, session):
    indexed = {row['sequence']: row for row in rows}
    assert rows and all(all(row[key] == session[key] for key in ('runID', 'pid', 'bundleID')) for row in rows)
    for receipt in receipts:
        for row in receipt['timeline']:
            original = indexed.get(row['sequence'], {})
            assert all(original.get(key) == value for key, value in row.items()), 'Inspector timeline differs from runtime journal'
        projected = {row['uuid']: row for row in rows if row['sequence'] <= receipt['cursor'] and row['event'] == 'call.changed'}
        assert {row['uuid'] for row in receipt['conversations']} == set(projected)
        for call in receipt['conversations']:
            assert all(projected[call['uuid']].get(key) == value for key, value in call.items())
        if 'timingReferences' in receipt:
            verify_timing_reference_journal(receipt, rows)

        if 'incomingFilter' in receipt:
            configured = [row for row in rows if row['sequence'] <= receipt['cursor']
                          and row['event'] == 'incomingFilter.configured']
            assert receipt['incomingFilter'] == (configured[-1]['reason'] if configured else 'none')


def journal_mute_value(action, rows):
    """Resolve native mute parameters without trusting the Inspector's projection."""
    identity = ('schemaVersion', 'runID', 'pid', 'bundleID')
    if not all(type(action.get(key)) is str and action[key] for key in ('transactionID', 'provider', 'actionID', 'callUUID')):
        return None
    transactions = [row for row in rows if row['event'] == 'transaction.delivered' and
                    all(key in row and key in action and row[key] == action[key] for key in identity) and
                    row.get('transactionID') == action['transactionID']]
    direct = action.get('muted')
    if not transactions:
        return direct if type(direct) is bool else None
    if len(transactions) != 1:
        return None
    transaction = transactions[0]
    if transaction.get('provider') != action['provider'] or transaction.get('origin') != action.get('origin'):
        return None
    if (type(transaction.get('sequence')) is not int or type(action.get('sequence')) is not int or
            transaction['sequence'] >= action['sequence'] or
            any(type(row.get('t_ms')) not in (int, float) or not math.isfinite(row['t_ms']) for row in (transaction, action)) or
            transaction['t_ms'] > action['t_ms']):
        return None
    actions, calls, kinds, parameters = [transaction.get(key) for key in ('actionIDs', 'callUUIDs', 'kinds', 'parameters')]
    if (not all(type(value) is list for value in (actions, calls, kinds, parameters)) or not actions or
            not len(actions) == len(calls) == len(kinds) == len(parameters) or
            not all(type(value) is str and value for value in actions + calls + kinds) or
            len(set(actions)) != len(actions) or not all(type(value) is dict for value in parameters) or
            action['actionID'] not in actions):
        return None
    index = actions.index(action['actionID'])
    value = parameters[index].get('muted')
    if (action.get('kind') != 'mute' or kinds[index] != 'CXSetMutedCallAction' or calls[index] != action['callUUID'] or
            type(value) is not bool or direct is not None and (type(direct) is not bool or direct != value)):
        return None
    return value


def verify_timing_reference_journal(receipt, rows, required=()):
    """Require measured values to cite retained, correlated original journal rows."""
    references = {'pushReport': '≈190 ms', 'answerAudio': '≈236 ms',
                  'muteEcho': '8–17 ms after fulfillment', 'unreportedPush': '≈4.4 s'}
    values = receipt['timingReferences']
    assert len(values) == 4 and {value['id'] for value in values} == set(references)
    indexed = {row['sequence']: row for row in rows}
    retained = {row['sequence'] for row in receipt['timeline']}
    originals = [indexed[sequence] for sequence in sorted(retained)]
    for value in values:
        name = value['id']
        assert value['deviceValue'] == references[name]
        assert 'LCK · iPhone 13 · iOS 27.0' in value['deviceProvenance']
        assert value['sourcePath'] == 'docs/research/callkit-simulator-probe/livecommunicationkit/push/README.md'
        actual = value.get('actualMS')
        if actual is None:
            assert name not in required, f'{name} actual is unavailable'
            assert value.get('startSequence') is None and value.get('endSequence') is None
            continue
        assert type(actual) in (int, float) and math.isfinite(actual) and actual >= 0
        start_sequence, end_sequence = value['startSequence'], value['endSequence']
        assert start_sequence in retained and end_sequence in retained and start_sequence < end_sequence
        start, end = indexed[start_sequence], indexed[end_sequence]
        assert all(start[key] == end[key] for key in ('schemaVersion', 'runID', 'pid', 'bundleID'))
        elapsed = end['t_ms'] - start['t_ms']
        assert math.isfinite(elapsed) and elapsed >= 0 and math.isclose(actual, elapsed, rel_tol=0, abs_tol=1e-6)
        if name in ('pushReport', 'unreportedPush'):
            candidates = [row for row in originals if row['event'] == 'push.received']
            assert candidates[-1]['sequence'] == start_sequence
            assert start.get('pushID') and start['pushID'] == end.get('pushID')
            expected = 'report.completed' if name == 'pushReport' else 'diagnostic.pushReportExpired'
            assert end['event'] == expected
            if name == 'unreportedPush':
                assert start.get('mustReport') is True
            else:
                assert type(end.get('error')) is int and end['error'] == 0
        elif name == 'answerAudio':
            candidates = [row for row in originals if row['event'] == 'action.deadline' and row.get('kind') == 'answer']
            assert candidates[-1]['sequence'] == start_sequence
            assert start.get('callUUID') and start.get('actionID') and end['event'] == 'audio.activated'
            label = {'callkit': 'CallKit answer', 'livecommunicationkit': 'LCK join'}.get(start.get('apiKind'))
            assert label and value['actualLabel'] == f'Simulator · {label} delivered → audio.activated'
            between = [row for row in originals if start_sequence < row['sequence'] < end_sequence]
            assert any(row['event'] == 'action.settled' and row.get('kind') == 'answer' and row.get('fulfilled') is True and
                       all(row.get(key) == start.get(key) for key in ('actionID', 'callUUID', 'apiKind')) for row in between)
            assert not any(row['event'] in ('action.deadline', 'action.settled') and
                           row.get('kind') in ('start', 'hold', 'end') for row in between)
            assert not any(row['event'] in ('action.deadline', 'action.settled') and row.get('kind') == 'answer' and
                           row.get('actionID') != start.get('actionID') for row in between)
        else:
            candidates = [row for row in originals if row['event'] == 'action.settled' and
                          row.get('kind') == 'mute' and row.get('origin') == 'application']
            assert candidates[-1]['sequence'] == start_sequence and start.get('fulfilled') is True
            assert end['event'] == 'action.deadline' and end.get('kind') == 'mute' and end.get('origin') == 'muteEcho'
            assert start.get('callUUID') and start['callUUID'] == end.get('callUUID')
            assert all(row.get(key) for row in (start, end) for key in ('actionID', 'transactionID'))
            identity = ('schemaVersion', 'runID', 'pid', 'bundleID')
            same_runtime = [row for row in originals if all(row.get(key) == start.get(key) for key in identity)]
            assert not any(row['sequence'] < end_sequence and row['event'] == 'action.deadline' and
                           row.get('actionID') == end['actionID'] for row in same_runtime), 'Echo action ID was already observed'
            assert not any(row['sequence'] < start_sequence and row['event'] == 'action.settled' and
                           row.get('fulfilled') is True and row.get('actionID') == start['actionID'] for row in same_runtime), 'Fulfillment action ID was already settled'
            muted = journal_mute_value(start, originals)
            assert type(muted) is bool and muted == journal_mute_value(end, originals)
            assert start.get('apiKind') in ('callkit', 'livecommunicationkit') and start['apiKind'] == end.get('apiKind')
            assert start.get('provider') and start['provider'] == end.get('provider')
            assert originals[0]['sequence'] == 1, 'Truncated history cannot establish outstanding mute obligations'
            mute_key = ('schemaVersion', 'runID', 'pid', 'bundleID', 'callUUID', 'apiKind', 'provider')
            outstanding, fulfilled_ids, delivery_ids = 0, set(), set()
            for row in same_runtime:
                if row['sequence'] >= end_sequence:
                    continue
                first_delivery = False
                if row['event'] == 'action.deadline' and type(row.get('actionID')) is str and row['actionID']:
                    first_delivery = row['actionID'] not in delivery_ids
                    delivery_ids.add(row['actionID'])
                if row.get('kind') != 'mute' or not all(row.get(key) == start.get(key) for key in mute_key):
                    continue
                fulfillment = row['event'] == 'action.settled' and row.get('origin') == 'application' and row.get('fulfilled') is True
                echo = row['event'] == 'action.deadline' and row.get('origin') == 'muteEcho'
                if not (fulfillment or echo):
                    continue
                resolved = journal_mute_value(row, originals)
                assert type(resolved) is bool, 'Unknown mute value leaves possible older obligations'
                if resolved != muted:
                    continue
                if row['sequence'] < start_sequence:
                    if fulfillment:
                        assert row.get('actionID') and row.get('transactionID')
                        if row['actionID'] not in fulfilled_ids:
                            fulfilled_ids.add(row['actionID'])
                            outstanding += 1
                    elif echo and first_delivery and row.get('transactionID'):
                        outstanding = max(0, outstanding - 1)
                elif start_sequence < row['sequence'] < end_sequence and fulfillment:
                    assert row.get('actionID') == start.get('actionID'), 'Competing app fulfillment makes mute echo ambiguous'
            assert outstanding == 0, 'Older outstanding app fulfillments make mute echo ambiguous'


@lru_cache(maxsize=1)
def _shipping_tools():
    return runpy.run_path(str(ROOT / 'Tools/cksim'))


def consumer_control(channel, session, target, deadline):
    """Load shipping mailbox controls once within the unchanged consumer budget."""
    assert session.get('controlTransport') == 'directory-watch-v1', 'spawn-free transport required'
    shipping = _shipping_tools()['control']

    def send(operation, *, command_receipt=None, **fields):
        budget = remaining_budget(deadline)
        args = SimpleNamespace(bundle=session['bundleID'], app_container=channel.parent.parent,
            runtime_dir=ROOT, timeout=min(5, budget),
            command_receipt=command_receipt, operation=operation, **fields)
        # Match the old subprocess bound, including shipping preflight/publication.
        def expired(*_):
            raise RuntimeError('Inspector control timed out; outcome is unknown; never retried')
        started = time.monotonic()
        previous_handler = signal.getsignal(signal.SIGALRM)
        previous_timer = signal.getitimer(signal.ITIMER_REAL)
        bound = min(8, budget, previous_timer[0] or float('inf'))
        signal.signal(signal.SIGALRM, expired)
        try:
            signal.setitimer(signal.ITIMER_REAL, bound)
            return json.dumps(shipping(args, target, expected_session=session))
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous_handler)
            if previous_timer[0]:
                signal.setitimer(signal.ITIMER_REAL,
                    max(0.000001, previous_timer[0] - (time.monotonic() - started)), previous_timer[1])
    return send


def foreground_control(target, session, channel, deadline, out):
    phases = []
    def foreground(bundle, pid):
        started = time.time() * 1000
        activate_existing(target, bundle, pid, deadline)
        if json.loads((channel / 'session.json').read_text()) != session:
            raise RuntimeError('Runtime session changed during foreground control')
        phases.append(dict(bundleID=bundle, pid=pid, startedWallTimeMS=started, finishedWallTimeMS=time.time() * 1000))
        (out / 'foreground-phases.json').write_text(json.dumps(phases))
        return started
    return foreground


def journal_journey(common, target, nonce, session, out, deadline, channel=None, probe=None):
    """Drive controls and require the foreground Inspector's consumed projections."""
    if probe is None:
        path = locate_probe(target, nonce, INSPECTOR)
        if path is None:
            raise RuntimeError('Validated Inspector receipt is unavailable')
        probe = ProbeReader(path, nonce, session, diagnostic_path=out / 'inspector-latest.json',
                            resume_log=out / 'inspector-resumes.jsonl', container=path.parent.parent)
    ready = probe.wait(lambda row: row['online'], timeout=10, deadline=deadline)
    deadline = min(deadline, time.monotonic() + 25 - (time.time() * 1000 - probe.started) / 1000)
    remaining_budget(deadline)
    assert not ready.get('incoming') and not ready['conversations'], 'fixture must start without a call'
    (out / 'inspector-online.json').write_text(json.dumps(ready))
    command = consumer_control(channel, session, target, deadline)
    foreground = foreground_control(target, session, channel, deadline, out)
    payload = out / 'incoming.json'
    payload.write_text(json.dumps(dict(operation='incoming')))
    foreground(session['bundleID'], session['pid'])
    assert json.loads(command('push', payload_file=payload, must_report='true'))['success']
    ringing = wait_runtime(lambda rows: any(row['event'] == 'call.changed' and row.get('ringing') for row in rows),
                           channel, session, deadline)
    native_call = next(row for row in reversed(ringing) if row['event'] == 'call.changed' and row.get('ringing'))
    resumed = foreground(INSPECTOR, probe.pid)
    incoming = probe.wait(lambda row: (row.get('incoming') or {}).get('uuid') == native_call['uuid'],
                          deadline=deadline, resume_after=resumed)
    call = incoming['incoming']
    identifier = str(uuid.UUID(call['uuid']))
    assert call.get('ringing') and not call.get('ended') and call.get('callerName') == 'Alex Morgan'
    (out / 'inspector-incoming.json').write_text(json.dumps(incoming))
    foreground(session['bundleID'], session['pid'])
    response = json.loads(command('answer', call=identifier, command_receipt=out / 'answer-control.json'))
    assert response['success']
    action_ids = set(response['result']['actionIDs'])
    assert action_ids
    def settled(rows):
        actions = [row for row in rows if row.get('actionID') in action_ids and row['event'] == 'action.settled']
        return ({row.get('actionID') for row in actions} == action_ids and
                all(row.get('fulfilled') and row.get('origin') == 'system' and row.get('kind') == 'answer' for row in actions) and
                any(row['event'] == 'audio.activated' for row in rows))
    wait_runtime(settled, channel, session, deadline)
    resumed = foreground(INSPECTOR, probe.pid)
    def answered(row):
        current = next((value for value in row['conversations'] if value.get('uuid') == call['uuid']), {})
        settled = [value for value in row['timeline'] if value.get('actionID') in action_ids and value['event'] == 'action.settled']
        return (current.get('connected') is True and row.get('incoming') is None and row['audioActive'] and
                not any(value.get('actionID') in action_ids for value in row['pending']) and
                {value.get('actionID') for value in settled} == action_ids and
                any(value['event'] == 'audio.activated' for value in row['timeline']))
    connected = probe.wait(answered, deadline=deadline, resume_after=resumed)
    assert connected['cursor'] > incoming['cursor']
    (out / 'inspector-answered.json').write_text(json.dumps(connected))
    captured = run(*common, 'watch', '--json', '--duration', '0.3', timeout=min(5, remaining_budget(deadline)))
    (out / 'events.jsonl').write_text(captured + '\n')
    rows = [json.loads(line) for line in captured.splitlines()]
    verify_probe_journal((incoming, connected), rows, session)
    verify_timing_reference_journal(connected, rows, required=('pushReport', 'answerAudio'))
    answers = [row for row in rows if row.get('actionID') in action_ids and row['event'] == 'action.settled']
    assert len(answers) == 1 and answers[0]['kind'] == 'answer' and answers[0]['origin'] == 'system' and answers[0]['fulfilled']
    assert math.isfinite(answers[0]['latencyMS']) and 0 <= answers[0]['latencyMS'] < answers[0]['deadlineSeconds'] * 1000
    presentation = next(row for row in connected['timelinePresentation'] if row['sequence'] == answers[0]['sequence'])
    assert (presentation['title'] == 'Answer fulfilled' and 'system' in presentation['detail'] and
            'profile budget' in presentation['detail'] and ' ms' in presentation['detail'])
    assert time.time() * 1000 - probe.started <= 25000, 'shared fixture background budget exceeded'
    remaining_budget(deadline)
    try:
        run('xcrun', 'simctl', 'io', target, 'screenshot', out / 'inspector-consumer.png', timeout=3)
    except (RuntimeError, OSError) as error:
        try:
            (out / 'screenshot-error.txt').write_text(str(error))
        except OSError:
            pass
    return dict(success=True, driver='journal', uiConsumer=True, answerLatencyMS=answers[0]['latencyMS'])


def filter_journey(common, target, nonce, session, out, deadline, channel, probe,
                   *, before, reason, code, verification):
    """Verify one filter transition within this consumer's original 25 seconds."""
    ready = probe.wait(lambda row: row['online'], timeout=10, deadline=deadline)
    deadline = min(deadline, time.monotonic() + 25 - (time.time() * 1000 - probe.started) / 1000)
    remaining_budget(deadline)
    assert ready.get('incomingFilter') == before, 'filter case must retain the preceding runtime setting'
    (out / 'inspector-online.json').write_text(json.dumps(ready))
    foreground = foreground_control(target, session, channel, deadline, out)
    foreground(session['bundleID'], session['pid'])
    command = consumer_control(channel, session, target, deadline)
    response = json.loads(command('incoming-filter', reason=reason,
                                  command_receipt=out / 'filter-control.json'))
    assert response['success'] and response['result']['incomingFilter'] == dict(
        reason=reason, code=code, verification=verification)
    request_id = response['id']
    def configured(row):
        return (row['sequence'] > ready['cursor'] and row['event'] == 'incomingFilter.configured'
                and row.get('requestID') == request_id and row.get('reason') == reason
                and row.get('code') == code and row.get('verification') == verification)
    wait_runtime(lambda rows: any(configured(row) for row in rows), channel, session, deadline)
    resumed = foreground(INSPECTOR, probe.pid)
    receipt = probe.wait(lambda row: row.get('incomingFilter') == reason and
                         any(configured(event) for event in row['timeline']),
                         deadline=deadline, resume_after=resumed)
    assert receipt['conversations'] == ready['conversations'], 'filter changed an existing call'
    assert receipt['audioActive'] == ready['audioActive'], 'filter changed existing audio'
    (out / ('inspector-filter-' + reason + '.json')).write_text(json.dumps(receipt))
    captured = run(*common, 'watch', '--json', '--duration', '0.3', timeout=min(5, remaining_budget(deadline)))
    (out / 'events.jsonl').write_text(captured + '\n')
    verify_probe_journal((ready, receipt), [json.loads(line) for line in captured.splitlines()], session)
    assert time.time() * 1000 - probe.started <= 25000, 'shared fixture background budget exceeded'
    remaining_budget(deadline)
    return dict(success=True, reason=reason, requestID=request_id, nonce=nonce, inspectorPID=probe.pid)


def run_filter_cases(common, target, connection, session, channel, out):
    results = []
    for before, reason, code, verification in (
            ('none', 'do-not-disturb', 3, 'verified'),
            ('do-not-disturb', 'none', 0, 'not-applicable')):
        case_out = out / ('filter-' + reason)
        case_out.mkdir()
        read_runtime_journal(channel, session)
        # A planned new consumer needs a live target bridge before its own
        # launch boundary. This never extends or restarts an existing consumer.
        activate_existing(target, session['bundleID'], session['pid'], time.monotonic() + 20)
        nonce = str(uuid.uuid4())
        probe, deadline = launch_inspector(connection, target, nonce, session, channel, case_out, True)
        result = filter_journey(common, target, nonce, session, case_out, deadline, channel, probe,
                                before=before, reason=reason, code=code, verification=verification)
        if result.get('success') is not True:
            raise RuntimeError('Inspector filter case did not succeed')
        results.append(result)
    return results


def journal_cases(common, target, nonce, session, out, deadline, channel, connection,
                  *, verify_filters=False, probe=None):
    result = journal_journey(common, target, nonce, session, out, deadline, channel, probe=probe)
    if result.get('success') is not True:
        raise RuntimeError('Inspector incoming/answer case did not succeed')
    if verify_filters:
        result['filterCases'] = run_filter_cases(common, target, connection, session, channel, out)
    return result


# Provided display: four 60s simctl calls, a 180s cold launch, and the status reply.
def wait_for_inspector(process, log, timeout=480, consumer_budget=None):
    deadline = time.monotonic() + timeout
    consumer_deadline = None
    while True:
        if process.poll() is not None:
            raise RuntimeError('Inspector exited during startup: ' + log.read_text())
        output = log.read_text()
        if consumer_budget is not None and 'Inspector: launching app on display simulator.' in output:
            if consumer_deadline is None:
                consumer_deadline = time.monotonic() + consumer_budget
            remaining_budget(consumer_deadline)
        if 'Inspector on ' in output:
            if consumer_budget is not None and consumer_deadline is None:
                raise RuntimeError('Inspector shared launch boundary was not observed')
            return consumer_deadline
        if time.monotonic() >= deadline:
            raise RuntimeError('Inspector launch timed out: ' + output)
        time.sleep(0.1)


def launch_inspector(connection, display, nonce, session, channel, out, shared):
    record_case_baseline(out, channel, session, out.name)
    probe = None
    def observe(resume_after=None):
        nonlocal probe
        path = locate_probe(display, nonce, INSPECTOR)
        if path is None:
            if probe is not None:
                raise RuntimeError('Inspector receipt disappeared during startup')
            return None
        if probe is None:
            probe = ProbeReader(path, nonce, session, diagnostic_path=out / 'inspector-latest.json',
                                resume_log=out / 'inspector-resumes.jsonl', container=path.parent.parent)
        elif path != probe.path:
            raise RuntimeError('Inspector data container changed during startup')
        value = probe.read(resume_after=resume_after)
        if value is not None and value['online']:
            verify_probe_journal((value,), read_runtime_journal(channel, session), session)
        return value
    _, deadline = supervise_launch(
        ['xcrun', 'simctl', 'launch', '--terminate-running-process', display, INSPECTOR],
        env=dict(os.environ, **connection.launch_environment, SIMCTL_CHILD_CKSIM_INSPECTOR_PROBE_NONCE=nonce),
        log=out / 'inspector-launch.log', observe=observe, bridge_alive=connection.is_alive,
        host_timeout=20 if shared else 180, consumer_timeout=25 if shared else None,
        redactions=tuple(connection.launch_environment.values()), bundle=INSPECTOR)
    if deadline is not None:
        deadline = min(deadline, time.monotonic() + 25 - (time.time() * 1000 - probe.started) / 1000)
        remaining_budget(deadline)
    return probe, deadline


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--inspector', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--target-simulator')
    parser.add_argument('--fixture-installed', action='store_true',
                        help='Reuse the fixture installed by native acceptance on the supplied target')
    parser.add_argument('--display-simulator')
    parser.add_argument('--runtime', help='Require this exact available simulator runtime identifier')
    parser.add_argument('--driver', choices=('xctest', 'journal'), default='xctest')
    parser.add_argument('--verify-filter-controls', action='store_true', help='Verify journal-driver filter selection and clearing')
    args = parser.parse_args()
    if args.verify_filter_controls and args.driver != 'journal':
        parser.error('--verify-filter-controls requires --driver journal')
    if args.fixture_installed and not args.target_simulator:
        parser.error('--fixture-installed requires an explicit --target-simulator')
    if args.driver == 'journal' and args.display_simulator and args.display_simulator != args.target_simulator:
        parser.error('The journal driver uses its target simulator as the Inspector display')
    out = args.out.resolve()
    out.mkdir(parents=True)
    project = ROOT / 'Tests/Inspector/UITests.xcodeproj'
    build = out / 'ui-build'
    if args.driver == 'xctest':
        with (out / 'ui-build.log').open('w') as log:
            subprocess.run(['xcodebuild','build-for-testing','-project',str(project),'-scheme','InspectorUITests',
                            '-destination','generic/platform=iOS Simulator','-derivedDataPath',str(build),
                            'CODE_SIGNING_ALLOWED=NO'], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=300)
    runtimes = json.loads(run('xcrun','simctl','list','runtimes','-j'))['runtimes']
    runtime = latest_runtime(runtimes, args.runtime)
    record_environment(out, runtime)
    print('Selected simulator runtime: ' + runtime, flush=True)
    owned = []
    bridge_context = tests = probe = None
    target = display = None
    channel = None
    def device(supplied, name):
        if supplied:
            return supplied
        value = run('xcrun','simctl','create',name + str(uuid.uuid4())[:8],
                    'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro',runtime)
        owned.append(value)
        run('xcrun','simctl','boot',value)
        run('xcrun','simctl','bootstatus',value,'-b',timeout=300)
        return value
    try:
        target = device(args.target_simulator, 'M4 Target ')
        print('Starting a fresh fixture session on the target simulator.', flush=True)
        channel, run_id = launch_fixture(target, args.fixture, install=not args.fixture_installed)
        session = fixture_session(channel, run_id)
        assert session.get('controlTransport') == 'directory-watch-v1', 'fixture must support spawn-free mailbox controls'
        common = [str(ROOT/'Tools/cksim'),'--simulator',target,'--bundle',BUNDLE,
                  '--runtime-dir',str(args.package.resolve()), '--app-container', str(channel.parent.parent)]
        journal = args.driver == 'journal'
        nonce = str(uuid.uuid4())
        display = target if journal else device(args.display_simulator, 'M4 Inspector ')
        # Load shipping functions before the shared consumer lifetime starts.
        factory = _shipping_tools()['inspector_bridge']
        bridge_args = SimpleNamespace(bundle=BUNDLE, app_container=channel.parent.parent,
                                      runtime_dir=args.package.resolve(), timeout=15)
        context = factory(bridge_args, target)
        connection = context.__enter__()
        bridge_context = context
        if dict(connection.session) != session or connection.target_container != channel.parent.parent:
            raise RuntimeError('Inspector bridge target changed before native launch')
        if not journal and uuid.UUID(display) == uuid.UUID(target):
            raise RuntimeError('Use a separate inspector simulator so the target app stays in the foreground.')
        run('xcrun', 'simctl', 'install', display, args.inspector.resolve(), timeout=60)
        probe, consumer_deadline = launch_inspector(connection, display, nonce, session, channel, out, journal)
        if journal:
            print(json.dumps(journal_cases(common, target, nonce, session, out, consumer_deadline, channel,
                                          connection, verify_filters=args.verify_filter_controls, probe=probe)))
            return
        with (out / 'ui-test.log').open('w') as log:
            tests = subprocess.Popen(['xcodebuild','test-without-building','-project',str(project),'-scheme','InspectorUITests',
                                      '-destination','platform=iOS Simulator,id='+display,'-derivedDataPath',str(build),
                                      '-resultBundlePath',str(out/'inspector.xcresult'),'CODE_SIGNING_ALLOWED=NO',
                                      '-parallel-testing-enabled','NO','-collect-test-diagnostics','never'], stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline and tests.poll() is None:
            started = next((line for line in (out/'ui-test.log').read_text().splitlines()
                            if 'Test Case ' in line and 'testAnswerFromInspector' in line and 'started.' in line), None)
            if started:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError('UI test did not start: ' + (out/'ui-test.log').read_text()[-2000:])
        payload = out / 'incoming.json'
        payload.write_text(json.dumps(dict(operation='incoming')))
        timing = dict(testCaseStartLine=started, pushCommandStartedAtMS=int(time.time() * 1000))
        (out/'stimulus-timing.json').write_text(json.dumps(timing))
        run(*common,'push','--payload-file',payload,'--must-report','true')
        timing['pushCommandFinishedAtMS'] = int(time.time() * 1000)
        (out/'stimulus-timing.json').write_text(json.dumps(timing))
        code = tests.wait(timeout=300)
        captured = run(*common, 'watch','--json','--duration','0.3')
        (out/'events.jsonl').write_text(captured+'\n')
        rows = [json.loads(line) for line in captured.splitlines()]
        assert code == 0, (out/'ui-test.log').read_text()[-4000:]
        assert all(all(row[k] == session[k] for k in ('runID', 'pid', 'bundleID')) for row in rows)
        answers = [r for r in rows if r['event']=='action.settled' and r['kind']=='answer']
        assert len(answers)==1 and answers[0]['origin']=='system' and answers[0]['fulfilled']
        assert any(r['event']=='audio.activated' for r in rows)
        run('xcrun','xcresulttool','export','attachments','--path',out/'inspector.xcresult','--output-path',out/'screenshots')
        (out/'environment.txt').write_text(run('xcodebuild','-version')+'\n'+runtime+'\n')
        print(json.dumps(dict(success=True, answerLatencyMS=answers[0]['latencyMS'], screenshots='screenshots/')))
    finally:
        failure = sys.exc_info()
        failed = failure[0] is not None
        operations = []
        if target:
            operations.append(lambda: capture_diagnostics(out, target, channel=channel, failed=failed))
        if failed and display:
            evidence = probe.path.parent if probe else out / 'unpublished-inspector-channel'
            operations.append(lambda: capture_diagnostics(out / 'display', display, bundle=INSPECTOR, channel=evidence, failed=True))
        def stop(process):
            if process is not None and process.poll() is None:
                process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        operations.append(lambda: stop(tests))
        if bridge_context is not None:
            operations.append(lambda: bridge_context.__exit__(*failure))
        operations.append(lambda: remove_simulators(owned))
        cleanup_operations(failure[1], operations)


if __name__ == '__main__':
    main()
