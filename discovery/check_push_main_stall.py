#!/usr/bin/env python3
"""Synthetic controls of the direct native-owner main-stall gate; no native claim."""
from pathlib import Path
import copy
import hashlib
import json

from push_main_stall_conformance import BUNDLE, PROFILE, qualify_main_stall_journal

RUN_ID = '02b7d0cd-a398-455e-a0ae-cfd675fd5225'
SIMULATOR_ID = '410c9242-5418-4350-9743-5b218c335041'
CALL_ID = '9F431AB0-28D2-4F19-A0A2-B2A1B8EF1172'


def synthetic_fixture(run_id, pid):
    """Return synthetic runtime rows + observation fields, without probe envelope.

    Shared only with host complete-capture controls; never a native trace or a
    shipping gate override. The caller adds probe identity/sequence/time fields.
    """
    owner = '0x1234abcd'
    scope = dict(owner=owner, fixtureID=run_id + '-native-main-stall')
    events = [
        ('provider.created', 0, dict(provider='ObjectIdentifier(0x0000000012349876)')),
        ('fixture.mainStallBegan', 100, dict(scope, seconds=3, main=True)),
        ('fixture.nativeCallbackBegin', 101, dict(scope, main=False)),
        ('report.incoming', 101, dict(callUUID=CALL_ID, pushID='')),
        ('fixture.nativeCallbackReturned', 2101, dict(scope, main=False)),
        ('fixture.mainStallEnded', 3100, dict(scope, elapsedSeconds=3.0, main=True)),
        ('report.completed', 3102, dict(callUUID=CALL_ID, pushID='', error=0)),
        ('fixture.nativeCompletion', 3103, dict(scope, ordinal=1, main=False)),
    ]
    rows = [dict(fields, event=event, sequence=index + 1, t_ms=timestamp,
                 runID=run_id, pid=pid, bundleID=BUNDLE, profile=PROFILE)
            for index, (event, timestamp, fields) in enumerate(events)]
    observation = dict(scope, event='entry.mainStallObservation', conversationID=CALL_ID,
        completionCount=1, callbackReturned=True, conversations=[dict(id=CALL_ID,
        status='ringing', direction='incoming', payload=dict(eventId='main-stall-event',
        serverCallId='main-stall-server', caller=dict(id='main-stall-caller', displayName='Main stall fixture'), hasVideo=False))])
    return rows, observation


def probe_fixture(observation, run_id=RUN_ID, pid=123):
    fields = [dict(event='app.entry'), dict(event='launch', case='sdk-main-stall'), observation,
              dict(event='entry.capture', boundariesObserved=True), dict(event='done')]
    return [dict(row, sequence=index + 1, t_ms=index, runID=run_id, pid=pid,
                 bundleID=BUNDLE, simulatorID=SIMULATOR_ID, main=True)
            for index, row in enumerate(fields)]


def main():
    runtime, observation = synthetic_fixture(RUN_ID, 123)
    probes = probe_fixture(observation)
    positives = [qualify_main_stall_journal(runtime, probes, RUN_ID, 123)]
    # Codable may omit nil fields or preserve them as null. Completion executor
    # is observed, not constrained to an unmeasured system callback queue.
    nulls = copy.deepcopy(probes)
    payload = nulls[2]['conversations'][0]['payload']
    payload.update(startedAt=None, metadata=None)
    payload['caller'].update(avatarUrl=None, phoneNumber=None, email=None)
    main_completion = copy.deepcopy(runtime)
    main_completion[-1]['main'] = True
    positives.append(qualify_main_stall_journal(main_completion, nulls, RUN_ID, 123))
    tied = copy.deepcopy(runtime)
    tied[4]['t_ms'] = tied[3]['t_ms']
    positives.append(qualify_main_stall_journal(tied, probes, RUN_ID, 123))

    def event(rows, name): return next(row for row in rows if row['event'] == name)
    def remove(rows, name): rows.remove(event(rows, name))
    def duplicate(rows, name):
        extra = copy.deepcopy(event(rows, name))
        extra['t_ms'] = rows[-1]['t_ms']
        rows.append(extra)
    def move(rows, name, target, after=False):
        row = event(rows, name); rows.remove(row)
        rows.insert(rows.index(event(rows, target)) + int(after), row)
        # Preserve a valid monotonic clock so this control tests causal sequence.
        times = sorted(row['t_ms'] for row in rows)
        for row, timestamp in zip(rows, times): row['t_ms'] = timestamp
    def resequence(rows):
        for index, row in enumerate(rows): row['sequence'] = index + 1
    def payload(rows): return rows[2]['conversations'][0]['payload']

    cases = [
        ('report-before-stall', lambda r,p: move(r,'report.incoming','fixture.mainStallBegan')),
        ('report-after-return', lambda r,p: move(r,'report.incoming','fixture.nativeCallbackReturned',True)),
        ('report-after-stall', lambda r,p: move(r,'report.incoming','fixture.mainStallEnded',True)),
        ('missing-report', lambda r,p: remove(r,'report.incoming')),
        ('multiple-report', lambda r,p: duplicate(r,'report.incoming')),
        ('missing-settlement', lambda r,p: remove(r,'report.completed')),
        ('multiple-settlement', lambda r,p: duplicate(r,'report.completed')),
        ('wrong-report-uuid', lambda r,p: event(r,'report.incoming').update(callUUID=RUN_ID)),
        ('invalid-report-uuid', lambda r,p: event(r,'report.incoming').update(callUUID='uuid')),
        ('failed-settlement', lambda r,p: event(r,'report.completed').update(error=2)),
        ('boolean-settlement-code', lambda r,p: event(r,'report.completed').update(error=False)),
        ('missing-native-completion', lambda r,p: remove(r,'fixture.nativeCompletion')),
        ('duplicate-native-completion', lambda r,p: duplicate(r,'fixture.nativeCompletion')),
        ('completion-before-settlement', lambda r,p: move(r,'fixture.nativeCompletion','report.completed')),
        ('settlement-before-stall-end', lambda r,p: move(r,'report.completed','fixture.mainStallEnded')),
        ('wrong-completion-ordinal', lambda r,p: event(r,'fixture.nativeCompletion').update(ordinal=2)),
        ('boolean-completion-ordinal', lambda r,p: event(r,'fixture.nativeCompletion').update(ordinal=True)),
        ('wrong-owner', lambda r,p: event(r,'fixture.nativeCallbackBegin').update(owner='0x4321')),
        ('zero-owner', lambda r,p: [row.update(owner='0x0') for row in r if 'owner' in row]),
        ('fabricated-owner', lambda r,p: [row.update(owner='owner') for row in r if 'owner' in row]),
        ('wrong-fixture-id', lambda r,p: event(r,'fixture.nativeCallbackReturned').update(fixtureID='other')),
        ('main-callback', lambda r,p: event(r,'fixture.nativeCallbackBegin').update(main=True)),
        ('main-return', lambda r,p: event(r,'fixture.nativeCallbackReturned').update(main=True)),
        ('worker-stall-begin', lambda r,p: event(r,'fixture.mainStallBegan').update(main=False)),
        ('worker-stall-end', lambda r,p: event(r,'fixture.mainStallEnded').update(main=False)),
        ('untyped-completion-thread', lambda r,p: event(r,'fixture.nativeCompletion').update(main=0)),
        ('short-stall-observation', lambda r,p: event(r,'fixture.mainStallEnded').update(elapsedSeconds=2.8)),
        ('nonfinite-stall-observation', lambda r,p: event(r,'fixture.mainStallEnded').update(elapsedSeconds=float('nan'))),
        ('boolean-requested-stall', lambda r,p: event(r,'fixture.mainStallBegan').update(seconds=True)),
        ('short-runtime-clock-span', lambda r,p: [row.update(t_ms=index) for index,row in enumerate(r)]),
        ('artificial-push-boundary', lambda r,p: r.append(dict(r[-1],event='push.received',pushID=RUN_ID+'-0'))),
        ('push-associated-report', lambda r,p: event(r,'report.incoming').update(pushID=RUN_ID+'-0')),
        ('missing-explicit-empty-push-id', lambda r,p: event(r,'report.incoming').pop('pushID')),
        ('probe-injection', lambda r,p: p.insert(2,dict(p[2],event='entry.inject'))),
        ('wrong-public-owner', lambda r,p: p[2].update(owner='0x4321')),
        ('wrong-public-fixture', lambda r,p: p[2].update(fixtureID='other')),
        ('wrong-public-uuid', lambda r,p: p[2].update(conversationID=RUN_ID)),
        ('duplicate-public-observation', lambda r,p: duplicate(p,'entry.mainStallObservation')),
        ('wrong-public-completion-count', lambda r,p: p[2].update(completionCount=2)),
        ('boolean-public-completion-count', lambda r,p: p[2].update(completionCount=True)),
        ('missing-public-return', lambda r,p: p[2].update(callbackReturned=False)),
        ('no-public-conversation', lambda r,p: p[2].update(conversations=[])),
        ('two-public-conversations', lambda r,p: p[2]['conversations'].append(copy.deepcopy(p[2]['conversations'][0]))),
        ('wrong-public-state', lambda r,p: p[2]['conversations'][0].update(status='connected')),
        ('wrong-public-direction', lambda r,p: p[2]['conversations'][0].update(direction='outgoing')),
        ('wrong-public-event', lambda r,p: payload(p).update(eventId='other')),
        ('wrong-public-server', lambda r,p: payload(p).update(serverCallId='other')),
        ('wrong-public-caller', lambda r,p: payload(p)['caller'].update(id='other')),
        ('wrong-public-name', lambda r,p: payload(p)['caller'].update(displayName='other')),
        ('false-public-video-type', lambda r,p: payload(p).update(hasVideo=0)),
        ('unexpected-public-metadata', lambda r,p: payload(p).update(metadata={'invented':True})),
        ('wrong-runtime-pid', lambda r,p: r[3].update(pid=124)),
        ('boolean-runtime-pid', lambda r,p: r[3].update(pid=True)),
        ('wrong-runtime-run', lambda r,p: r[3].update(runID='other')),
        ('wrong-runtime-bundle', lambda r,p: r[3].update(bundleID='other')),
        ('wrong-runtime-profile', lambda r,p: r[3].update(profile='other')),
        ('wrong-probe-run', lambda r,p: p[2].update(runID='other')),
        ('wrong-probe-simulator', lambda r,p: p[2].update(simulatorID=RUN_ID)),
        ('worker-probe', lambda r,p: p[2].update(main=False)),
    ]
    refused = []
    for label, mutate in cases:
        r, p = copy.deepcopy(runtime), copy.deepcopy(probes)
        mutate(r,p)
        resequence(r); resequence(p)
        try: qualify_main_stall_journal(r,p,RUN_ID,123)
        except ValueError as error: refused.append(dict(control=label,reason=str(error)))
        else: raise AssertionError('main-stall gate accepted synthetic tamper: '+label)
    # These controls deliberately preserve malformed sequence/clock types.
    for label, mutate in [
        ('float-sequence',lambda r: r[3].update(sequence=4.0)),
        ('boolean-clock',lambda r: r[3].update(t_ms=True)),
        ('reversed-clock',lambda r: r[4].update(t_ms=0)),
    ]:
        r = copy.deepcopy(runtime); mutate(r)
        try: qualify_main_stall_journal(r,probes,RUN_ID,123)
        except ValueError as error: refused.append(dict(control=label,reason=str(error)))
        else: raise AssertionError('main-stall gate accepted '+label)
    files = [Path(__file__), Path(__file__).with_name('push_main_stall_conformance.py')]
    print(json.dumps(dict(success=True,classification='synthetic host gate controls only; no native evidence',
        positives=len(positives),negativeControls=len(refused),controls=refused,
        sourceSHA256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in files}),indent=2))


if __name__ == '__main__': main()
