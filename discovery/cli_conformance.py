#!/usr/bin/env python3
"""Exercise the shipped CLI/control plane against a real simulator app."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

device, package, output = sys.argv[1:]
package, output = Path(package).resolve(), Path(output).resolve()
bundle = 'dev.callkitsim.probe'
cli = [str(package / 'cksim'), '--simulator', device, '--bundle', bundle]
environment = {**os.environ, 'SIMCTL_CHILD_PROBE_MODE': 'push', 'SIMCTL_CHILD_PROBE_PUSH_WAIT': '180',
               'SIMCTL_CHILD_CKSIM_PUSH_AFTER': '', 'SIMCTL_CHILD_CKSIM_PUSH_TRIGGER_NOTIFICATION': '',
               'SIMCTL_CHILD_PROBE_PUSH_REPORT': 'report', 'SIMCTL_CHILD_CKSIM_LATENCY': 'device'}
receipts = []


def run(command, env=None):
    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=45)
    if result.returncode: raise RuntimeError(f'{command[0]} failed: {result.stderr}')
    return result.stdout.strip()


def command(*arguments):
    result = json.loads(run([*cli, *map(str, arguments)], environment))
    receipts.append(dict(operation=arguments[0], response=result))
    if not result.get('success', True): raise RuntimeError(str(result))
    return result.get('result', result)


def wait(predicate, label, timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value: return value
        time.sleep(0.05)
    raise RuntimeError('Timed out: ' + label)


def calls():
    return {c['uuid']: c for c in command('status')['calls']}


def journal():
    return [json.loads(line) for line in command('events')['events'].splitlines()]


def push(label, required):
    payload = output / f'cli-{label}-payload.json'
    payload.write_text(json.dumps({'from': '+15555550142', 'scenario': label}))
    before = set(calls())
    receipt = command('push', '--payload-file', payload, '--must-report', str(required).lower())
    current = wait(lambda: set(calls()) - before, 'incoming ' + label)
    if len(current) != 1: raise RuntimeError('Unexpected incoming inventory')
    received = [r for r in journal() if r['event'] == 'push.received' and r.get('pushID') == receipt['pushID']]
    assert len(received) == 1, 'missing uniquely correlated push receipt'
    actual = received[0]
    assert actual['api'] in ('metadata', 'legacy'), 'unsupported push API'
    assert actual['mustReport'] is (required if actual['api'] == 'metadata' else True), 'push reporting obligation changed'
    return next(iter(current)), receipt['pushID']


installed = False
try:
    run_id = str(uuid.uuid4()).upper()
    environment['SIMCTL_CHILD_CKSIM_RUN_ID'] = run_id
    command('launch')
    container = Path(run(['xcrun', 'simctl', 'get_app_container', device, bundle, 'data']))
    session_path = container / 'Documents/.callkit-simulator/session.json'
    wait(lambda: session_path.exists() and json.loads(session_path.read_text()).get('runID') == run_id, 'fresh runtime session')
    # Registry registration is asynchronous; this push deliberately exercises
    # pending delivery as well as the registered path.
    a, _ = push('a', False)
    wait(lambda: any(r['event'] == 'push.completed' for r in journal()), 'first push completion')
    command('answer', a)
    wait(lambda: calls().get(a, {}).get('connected') and command('status')['audioActive'], 'A connected with audio')
    command('faults', '--report-delay-ms', '1500')
    b, b_push = push('b', True)
    command('hold-and-accept', b, '--active-call', a)
    wait(lambda: calls().get(a, {}).get('held') and calls().get(b, {}).get('connected'), 'Hold & Accept')
    wait(lambda: any(r['event'] == 'report.completed' and r.get('pushID') == b_push for r in journal()), 'delayed report completion')
    rows = journal()
    connected = next(r for r in rows if r['event'] == 'call.changed' and r['uuid'] == b and r['connected'])
    completed = next(r for r in rows if r['event'] == 'report.completed' and r.get('pushID') == b_push)
    assert connected['sequence'] < completed['sequence'], 'early answer did not precede report callback'
    command('end', a)
    wait(lambda: a not in calls(), 'held A ended')
    c, _ = push('c', False)
    command('end-and-accept', c, '--active-call', b)
    wait(lambda: b not in calls() and calls().get(c, {}).get('connected'), 'End & Accept')
    d, _ = push('d', True)
    command('decline', d)
    wait(lambda: d not in calls() and calls().get(c, {}).get('connected'), 'Decline waiting leaves C connected')
    command('end', c)
    wait(lambda: not calls() and not command('status')['audioActive'], 'empty inactive final state')
    rows = journal()
    compositions = [r for r in rows if r['event'] == 'transaction.delivered' and len(r['actionIDs']) == 2]
    assert [r['kinds'] for r in compositions] == [
        ['CXSetHeldCallAction', 'CXAnswerCallAction'], ['CXEndCallAction', 'CXAnswerCallAction']]
    audio = [r['event'] for r in rows if r['event'] in ('audio.activated', 'audio.deactivated')]
    assert audio == ['audio.activated', 'audio.deactivated'] * 3, audio
    g, _ = push('ring-timeout', True)
    wait(lambda: g not in calls(), 'unanswered ringing timeout', timeout=66)
    rows = journal()
    accepted_g = next(r for r in rows if r['event'] == 'report.incoming' and r['callUUID'] == g)
    ended_g = next(r for r in rows if r['event'] == 'call.changed' and r['uuid'] == g and r['ended'])
    assert 59_500 <= ended_g['t_ms'] - accepted_g['t_ms'] <= 61_500, 'ring timeout profile budget'
    (output / 'cli.engine.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
    run(['xcrun', 'simctl', 'terminate', device, bundle])
    # Launch without per-process injection: the selected-bundle loader must work
    # and uninstall must restore exactly the previous launchd environment.
    command('install'); installed = True
    loader_run = str(uuid.uuid4()).upper()
    loader_env = {**environment, 'SIMCTL_CHILD_CKSIM_RUN_ID': loader_run}
    loader_env.pop('SIMCTL_CHILD_DYLD_INSERT_LIBRARIES', None)
    run(['xcrun', 'simctl', 'launch', device, bundle], loader_env)
    wait(lambda: json.loads(session_path.read_text()).get('runID') == loader_run, 'loader launch')
    assert command('status')['calls'] == []
    run(['xcrun', 'simctl', 'terminate', device, bundle])
    command('uninstall'); installed = False
    result = dict(success=True, scenarios=['direct launch', 'synthetic optional/required push', 'answer before report callback',
        'Hold & Accept', 'End & Accept', 'Decline waiting', 'audio handoff', '60.1s ringing timeout', 'allowlisted loader launch', 'uninstall'], mediaProof=False)
finally:
    subprocess.run(['xcrun', 'simctl', 'terminate', device, bundle], capture_output=True)
    if installed: command('uninstall')
    (output / 'cli.receipts.json').write_text(json.dumps(receipts, indent=2) + '\n')
print(json.dumps(result, indent=2))
