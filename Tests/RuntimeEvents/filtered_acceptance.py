"""Native filtered-report acceptance using one already-connected fixture session.

The caller owns simulator lifecycle and supplies cached-container CLI controls.
This module never invokes simctl, restarts the app, or substitutes journal rows
for the fixture's actual report-completion NSError callback.
"""
import json
import math
from pathlib import Path
import runpy
import time
from types import SimpleNamespace
import uuid

DOMAIN = 'com.apple.CallKit.error.incomingcall'
HANDLE = '+12025550123'
FILTERS = [('do-not-disturb', 3, 'verified'),
           ('restricted-sharing-mode', 5, 'unverified'), ('call-is-protected', 6, 'unverified'),
           ('sensitive-participants', 7, 'unverified')]
FAULT_SNAPSHOT_DELAY_MS = 5000  # Explicit test injection, not measured device timing.


def snapshot_control(channel, session):
    """Load shipping control once, retaining its cached-container/session guards."""
    assert session.get('controlTransport') == 'directory-watch-v1', 'spawn-free transport required'
    container = Path(channel).parent.parent
    device = container.parents[4].name
    shipping = runpy.run_path(str(Path(__file__).resolve().parents[2] / 'Tools/cksim'))['control']

    def send(operation, **fields):
        args = SimpleNamespace(bundle=session['bundleID'], app_container=container,
            runtime_dir=Path(__file__).resolve().parents[2], timeout=5, command_receipt=None,
            operation=operation, **fields)
        response = shipping(args, device, expected_session=session)
        assert response.get('success'), response
        return response
    return send


def mutate_pending_fault(*, control, rows, wait, payload, call_uuid):
    """Keep process startup outside the pending-report mutation interval."""
    configured = control('faults', incoming_error_code=4, report_delay_ms=FAULT_SNAPSHOT_DELAY_MS)
    assert configured['result']['incomingErrorCode'] == 4, configured
    cursor = len(rows())
    payload.write_text(json.dumps(dict(operation='incoming', callUUID=call_uuid)))
    pushed = control('push', payload_file=payload, must_report='true')
    assert pushed['result'].get('scheduled') is True, pushed
    push_id = pushed['result']['pushID']
    entry = wait(lambda: next((r for r in rows()[cursor:] if r['event'] == 'report.incoming'
                              and r.get('pushID') == push_id), None))
    selected = control('incoming-filter', reason=FILTERS[1][0])
    assert selected['result']['incomingFilter'] == dict(zip(('reason', 'code', 'verification'), FILTERS[1]))
    changed = control('faults', incoming_error_code=0, report_delay_ms=1000)
    assert changed['result']['incomingErrorCode'] == 0, changed
    return cursor, push_id, entry, selected['id'], changed['id']


def assert_snapshot_mutations(rows, *, call_uuid, entry, filter_request, fault_request):
    done = next(r for r in rows if r['event'] == 'report.completed' and r.get('reportID') == entry['reportID'])
    callback = next(r for r in rows if r['event'] == 'fixture.reportCompleted' and r.get('callUUID') == call_uuid)
    mutations = {}
    for event, request in [('incomingFilter.configured', filter_request), ('faults.configured', fault_request)]:
        matches = [r for r in rows if r['event'] == event and r.get('requestID') == request]
        assert len(matches) == 1, ('missing snapshot mutation', event, request)
        assert entry['sequence'] < matches[0]['sequence'] < done['sequence'] < callback['sequence'], (
            'snapshot mutation must precede runtime completion and actual callback', matches[0], done, callback)
        mutations[event] = matches[0]['sequence']
    return dict(entrySequence=entry['sequence'], mutationSequences=mutations,
                completionSequence=done['sequence'], callbackSequence=callback['sequence'],
                injectedDelayMS=FAULT_SNAPSHOT_DELAY_MS, timingEvidence='unverified test injection')


def assert_rejected_interval(rows, *, filtered_uuids, previous_actions=None):
    """Reject report side effects while allowing already-issued legacy expiry.

    An empty live status can still have fulfilled CallKit post-end unmute
    actions whose measured policy emits expiry/timeout later. Only identities
    pinned from action.deadline before filtering may finish this way.
    """
    previous_actions = previous_actions or {}
    for row in rows:
        event = row['event']
        assert event != 'call.changed', ('rejected report created call state', row)
        assert event not in ('audio.activated', 'fault.audioSuppressed'), ('rejected report activated audio', row)
        assert not (event == 'audio.failed' and row.get('activating') is True), ('rejected report attempted audio activation', row)
        assert event != 'transaction.delivered', ('rejected report delivered a transaction', row)
        if event.startswith('action.'):
            action_id, call_uuid = row.get('actionID'), row.get('callUUID')
            expected_old_timeout = (event in ('action.expired', 'action.timeout')
                and action_id in previous_actions and call_uuid == previous_actions[action_id]
                and call_uuid not in filtered_uuids)
            assert expected_old_timeout, ('rejected report caused a new or related action', row)


def assert_report_attempt(rows, *, call_uuid, push_id, reason, code, verification,
                          expected_delay_ms=None, previous_actions=None):
    """Assert observable report/callback evidence from one stimulus onward."""
    incoming = [r for r in rows if r['event'] == 'report.incoming' and r.get('callUUID') == call_uuid]
    completed = [r for r in rows if r['event'] == 'report.completed' and r.get('callUUID') == call_uuid]
    callbacks = [r for r in rows if r['event'] == 'fixture.reportCompleted' and r.get('callUUID') == call_uuid]
    assert len(incoming) == len(completed) == 1, ('one runtime report attempt required', incoming, completed)
    assert len(callbacks) == 1, ('one actual callback required', callbacks)
    entry, done, callback = incoming[0], completed[0], callbacks[0]
    assert entry.get('reportID') and entry['reportID'] == done.get('reportID'), 'reportID must correlate entry and completion'
    domain = DOMAIN if code else ''
    for row in (entry, done):
        assert (row.get('code'), row.get('domain'), row.get('filterReason'), row.get('verification')) == (
            code, domain, reason, verification), row
        assert row.get('pushID') == push_id, row
    assert entry.get('latencyMS') == 0 and done.get('error') == code, (entry, done)
    assert callback.get('code') == code and callback.get('domain') == domain, callback
    assert callback.get('replyCount') == 1 and callback.get('main') is True, callback
    assert callback.get('handle') == HANDLE, callback
    assert entry['t_ms'] <= done['t_ms'] <= callback['t_ms'], (entry, done, callback)
    if expected_delay_ms is not None:
        for row in (done, callback):
            latency = row.get('latencyMS', -1)
            assert math.isfinite(latency) and latency >= expected_delay_ms - 150, row
        elapsed = done['t_ms'] - entry['t_ms']
        assert math.isfinite(elapsed) and elapsed >= expected_delay_ms - 150, (entry, done)
    for event in ('push.completed', 'push.callbackReturned'):
        observed = [r for r in rows if r['event'] == event and r.get('pushID') == push_id]
        assert len(observed) == 1 and observed[0].get('reportEntered') is True, (event, observed)
    assert not any(r['event'] in ('diagnostic.pushReportingViolation', 'diagnostic.pushReportExpired') for r in rows), rows
    if code:
        assert_rejected_interval(rows, filtered_uuids={call_uuid}, previous_actions=previous_actions)
    return dict(callUUID=call_uuid, reportID=entry['reportID'], pushID=push_id, code=code,
                reason=reason, verification=verification, reportLatencyMS=done['latencyMS'],
                callbackLatencyMS=callback['latencyMS'], entryMS=entry['t_ms'],
                callbackMain=callback['main'], replyCount=callback['replyCount'], handle=callback['handle'])


def run_filtered_acceptance(*, channel, session, command, rows, wait, out):
    """Prove filters 3/5–7, explicit fault 4, 69-second persistence, snapshots, and clearing.

    ``command`` is the existing CLI control closure, using the fixture's cached
    app-container path. ``rows`` and ``wait`` are the existing journal reader and
    bounded readiness helper. The original app PID/runID/journal are retained.
    """
    channel, out = Path(channel), Path(out)
    payload = out / 'filtered-push.json'
    original = {key: session[key] for key in ('runID', 'pid', 'bundleID')}
    attempts = []
    pending_control = snapshot_control(channel, session)

    def status():
        assert json.loads((channel / 'session.json').read_text()) == session, 'filtered acceptance changed runtime session'
        response = command('status')
        assert all(response.get(k) == v for k, v in original.items()), response
        return response['result']

    def empty():
        value = status()
        return value if not value['calls'] and value['pending'] == 0 and not value['audioActive'] else None

    def configure(reason, code, verification):
        expected = dict(reason=reason, code=code, verification=verification)
        response = command('incoming-filter', '--reason', reason)
        assert response['result']['incomingFilter'] == expected, response
        ack = wait(lambda: next((r for r in rows() if r['event'] == 'incomingFilter.configured'
                                and r.get('requestID') == response['id']), None))
        assert all(ack.get(key) == value for key, value in expected.items()), ack
        assert status()['incomingFilter'] == expected
        return ack

    def submit(call_uuid):
        payload.write_text(json.dumps(dict(operation='incoming', callUUID=call_uuid)))
        response = command('push', '--payload-file', payload, '--must-report', 'true')
        assert response['result'].get('scheduled') is True, response
        push_id = response['result']['pushID']
        entry = wait(lambda: next((r for r in rows() if r['event'] == 'report.incoming'
                                  and r.get('pushID') == push_id), None))
        return push_id, entry

    def finish(cursor, call_uuid, push_id, reason, code, verification, delay_ms=None):
        wait(lambda: any(r['event'] == 'fixture.reportCompleted' and r.get('callUUID') == call_uuid
                         for r in rows()[cursor:]))
        result = assert_report_attempt(rows()[cursor:], call_uuid=call_uuid, push_id=push_id,
            reason=reason, code=code, verification=verification, expected_delay_ms=delay_ms,
            previous_actions=previous_actions)
        attempts.append(result)
        return result

    def survive_until(deadline, expected_filter=None):
        # Keep querying the same PID's live mailbox while waiting. No process
        # liveness inference from a cached session file or a past journal row.
        while True:
            value = empty()
            assert value, 'filtered report left call/action/audio state'
            if expected_filter is not None:
                assert value['incomingFilter'] == expected_filter, 'selected filter did not persist'
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            time.sleep(min(0.5, remaining))

    initial = wait(empty)
    assert initial['incomingFilter'] == dict(reason='none', code=0, verification='not-applicable'), initial
    command('faults')
    history = rows()
    start_cursor = len(history)
    previous_actions = {r['actionID']: r['callUUID'] for r in history
                        if r['event'] == 'action.deadline' and r.get('actionID') and r.get('callUUID')}
    for reason, code, verification in FILTERS[1:]:
        configure(reason, code, verification)
        cursor = len(rows())
        call_uuid = str(uuid.uuid4()).upper()
        push_id, entry = submit(call_uuid)
        finish(cursor, call_uuid, push_id, reason, code, verification, delay_ms=2070)
        assert empty(), 'filtered result admitted a call or activated audio'

    # Code 4 is an explicit fault, not the natural LCK block-list outcome.
    # This larger fault-only delay is unverified injection, not DND timing.
    # Loaded shipping control avoids launching a Python CLI inside this window.
    configure('none', 0, 'not-applicable')
    fault_uuid = str(uuid.uuid4()).upper()
    cursor, fault_push, entry, filter_request, fault_request = mutate_pending_fault(
        control=pending_control, rows=rows, wait=wait, payload=payload, call_uuid=fault_uuid)
    finish(cursor, fault_uuid, fault_push, 'none', 4, 'injected-fault', delay_ms=FAULT_SNAPSHOT_DELAY_MS + 20)
    snapshot_evidence = assert_snapshot_mutations(rows()[cursor:], call_uuid=fault_uuid, entry=entry,
                                                 filter_request=filter_request, fault_request=fault_request)
    command('faults', '--report-delay-ms', '0')
    assert empty(), 'injected fault admitted a call or activated audio'

    configure(*FILTERS[0])
    dnd_selection = dict(reason='do-not-disturb', code=3, verification='verified')
    cursor = len(rows())
    first_uuid = str(uuid.uuid4()).upper()
    first_push, _ = submit(first_uuid)
    first_observed = time.monotonic()
    first = finish(cursor, first_uuid, first_push, *FILTERS[0], delay_ms=2070)
    survive_until(first_observed + 4.6, dnd_selection)
    # Keep the same DND selection for the entire 69-second interval. There is
    # no reconfiguration before the repeat that could hide an automatic clear.
    survive_until(first_observed + 69, dnd_selection)
    cursor = len(rows())
    repeat_uuid = str(uuid.uuid4()).upper()
    repeat_push, _ = submit(repeat_uuid)
    repeat_observed = time.monotonic()
    repeat = finish(cursor, repeat_uuid, repeat_push, *FILTERS[0], delay_ms=2070)
    assert repeat_uuid != first_uuid and repeat['entryMS'] - first['entryMS'] >= 69000, (first, repeat)
    assert repeat['handle'] == first['handle'] == HANDLE
    survive_until(repeat_observed + 4.6, dnd_selection)
    filtered_rows = rows()[start_cursor:]
    filtered_uuids = {a['callUUID'] for a in attempts}
    assert_rejected_interval(filtered_rows, filtered_uuids=filtered_uuids, previous_actions=previous_actions)

    # Clearing admits a normal call again. Reusing that admitted UUID under an
    # active filter must retain the pre-existing duplicate error code 2.
    configure('none', 0, 'not-applicable')
    cursor = len(rows())
    admitted_uuid = str(uuid.uuid4()).upper()
    admitted_push, _ = submit(admitted_uuid)
    finish(cursor, admitted_uuid, admitted_push, 'none', 0, 'not-applicable')
    wait(lambda: any(c['uuid'] == admitted_uuid for c in status()['calls']))
    configure(*FILTERS[0])
    cursor = len(rows())
    duplicate_push, _ = submit(admitted_uuid)
    finish(cursor, admitted_uuid, duplicate_push, 'none', 2, 'not-applicable')
    assert [c['uuid'] for c in status()['calls']] == [admitted_uuid], 'duplicate report changed admitted calls'
    command('end', admitted_uuid)
    wait(empty)
    configure('none', 0, 'not-applicable')
    final_rows = rows()[start_cursor:]
    assert len({a['reportID'] for a in attempts}) == len(attempts), 'each report attempt needs a unique reportID'
    for call_uuid in {a['callUUID'] for a in attempts}:
        callbacks = [r for r in final_rows if r['event'] == 'fixture.reportCompleted' and r.get('callUUID') == call_uuid]
        assert len(callbacks) == sum(a['callUUID'] == call_uuid for a in attempts), callbacks
        assert all(r['replyCount'] == 1 for r in callbacks), callbacks
    assert not any(r['event'] in ('diagnostic.pushReportingViolation', 'diagnostic.pushReportExpired') for r in final_rows)
    assert empty()
    result = dict(success=True, classification='native filtered NSError callback acceptance',
                  session=original, attempts=attempts, repeatGapMS=repeat['entryMS'] - first['entryMS'],
                  samePhoneHandle=HANDLE, samePIDSurvived=True, snapshotPreserved=True, injectedFaultCode=4,
                  snapshotEvidence=snapshot_evidence,
                  lckBlockedNumberOutcome='measured success; source #85',
                  clearedFilterAdmittedCall=True, duplicateUUIDCode=2)
    (out / 'filtered-acceptance.json').write_text(json.dumps(result, indent=2) + '\n')
    return result
