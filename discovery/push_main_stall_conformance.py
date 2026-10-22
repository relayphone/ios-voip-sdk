"""External gate for direct native-owner delivery while simulator main is stalled.

The enclosing capture validator must bind source/build/installed products,
supervisor, console and runtime session. This case invokes the real native owner
method directly; it is not PushKit delivery, CKSimInjectPush, APNs or cold launch.
"""
import math
import re

BUNDLE = 'dev.iosvoipsdk.pushentry'
PROFILE = 'ios-27.0'
UUID_PATTERN = r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
MARKERS = ('fixture.mainStallBegan', 'fixture.nativeCallbackBegin',
           'fixture.nativeCallbackReturned', 'fixture.mainStallEnded', 'fixture.nativeCompletion')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def valid_uuid(value):
    return isinstance(value, str) and re.fullmatch(UUID_PATTERN, value) is not None


def validate_rows(rows, run_id, pid, *, probes=False):
    require(isinstance(rows, list) and rows and all(isinstance(row, dict) for row in rows),
            'missing or malformed ' + ('probe' if probes else 'runtime') + ' rows')
    require(all(type(row.get('pid')) is int and row['pid'] == pid and row.get('runID') == run_id and
                row.get('bundleID') == BUNDLE for row in rows), 'mixed main-stall row identity')
    require([row.get('sequence') for row in rows] == list(range(1, len(rows) + 1)) and
            all(type(row.get('sequence')) is int and type(row.get('t_ms')) is int and row['t_ms'] >= 0 for row in rows) and
            all(a['t_ms'] <= b['t_ms'] for a, b in zip(rows, rows[1:])), 'invalid main-stall row sequence or clock')
    if probes:
        simulator = rows[0].get('simulatorID')
        require(valid_uuid(simulator) and all(row.get('simulatorID') == simulator and row.get('main') is True
                for row in rows), 'mixed probe simulator or unexpected probe executor')
    else:
        require(all(row.get('profile') == PROFILE for row in rows), 'mixed main-stall runtime profile')


def qualify_main_stall_journal(rows, probe_rows, run_id, pid):
    """Require actual provider entry before direct native return during main stall."""
    require(type(pid) is int and pid > 0 and valid_uuid(run_id), 'invalid expected main-stall identity')
    validate_rows(rows, run_id, pid)
    validate_rows(probe_rows, run_id, pid, probes=True)
    require(not any(str(row.get('event', '')).startswith('push.') or
                    row.get('event') == 'diagnostic.pushReportingViolation' or
                    row.get('pushID') not in (None, '') for row in rows),
            'direct native-owner case contains a push delivery or push association')
    require(not any(row.get('event') == 'entry.inject' for row in probe_rows),
            'direct native-owner case must not inject a PushKit delivery')
    require(not any(str(row.get('event', '')).startswith('fixture.') and row['event'] not in MARKERS
                    for row in rows), 'unexpected main-stall fixture marker')

    def one(event, cohort=rows):
        found = [row for row in cohort if row.get('event') == event]
        require(len(found) == 1, 'missing or repeated ' + event)
        return found[0]

    began, callback, returned, ended, completed = [one(event) for event in MARKERS]
    owner = began.get('owner')
    require(isinstance(owner, str) and re.fullmatch(r'0x[0-9a-fA-F]+', owner) is not None and int(owner, 16) != 0,
            'invalid actual native-owner pointer')
    fixture_id = run_id + '-native-main-stall'
    require(all(row.get('owner') == owner and row.get('fixtureID') == fixture_id
                for row in (began, callback, returned, ended, completed)),
            'main-stall markers are not bound to one actual owner and fixture')
    require(began.get('main') is True and ended.get('main') is True and
            callback.get('main') is False and returned.get('main') is False and
            type(completed.get('main')) is bool, 'false main-stall threading evidence')
    require(type(began.get('seconds')) in (int, float) and began['seconds'] == 3,
            'incorrect requested main stall')
    elapsed = ended.get('elapsedSeconds')
    require(type(elapsed) in (int, float) and math.isfinite(elapsed) and elapsed >= 2.9,
            'missing or short measured main stall')
    require(type(completed.get('ordinal')) is int and completed['ordinal'] == 1,
            'native completion cardinality differs')

    report = one('report.incoming')
    settlement = one('report.completed')
    call = report.get('callUUID')
    require(valid_uuid(call) and settlement.get('callUUID') == call,
            'actual report and settlement UUID differ')
    require(report.get('pushID') == '' and settlement.get('pushID') == '',
            'direct report unexpectedly has a push association')
    require(type(settlement.get('error')) is int and settlement['error'] == 0,
            'actual fresh-call report did not settle successfully')
    causal = (began, callback, report, returned, ended, settlement, completed)
    require(all(a['sequence'] < b['sequence'] for a, b in zip(causal, causal[1:])),
            'actual entry, direct return, stall end or completion order differs')
    span_ms = ended['t_ms'] - began['t_ms']
    require(span_ms >= 2900, 'runtime clock does not prove the main stall')

    observation = one('entry.mainStallObservation', probe_rows)
    require(observation.get('owner') == owner and observation.get('fixtureID') == fixture_id and
            observation.get('conversationID') == call and observation.get('callbackReturned') is True and
            type(observation.get('completionCount')) is int and observation['completionCount'] == 1,
            'unbound public main-stall observation')
    conversations = observation.get('conversations')
    require(isinstance(conversations, list) and len(conversations) == 1 and isinstance(conversations[0], dict),
            'public observation must contain one conversation')
    conversation = conversations[0]
    require(conversation.get('id') == call and conversation.get('status') == 'ringing' and
            conversation.get('direction') == 'incoming', 'public main-stall state differs')
    payload = conversation.get('payload')
    require(isinstance(payload, dict) and set(payload) <= {'eventId', 'serverCallId', 'caller', 'hasVideo', 'startedAt', 'metadata'} and
            payload.get('eventId') == 'main-stall-event' and payload.get('serverCallId') == 'main-stall-server' and
            payload.get('hasVideo') is False and payload.get('startedAt') is None and payload.get('metadata') is None,
            'public main-stall payload differs')
    caller = payload.get('caller')
    require(isinstance(caller, dict) and set(caller) <= {'id', 'displayName', 'avatarUrl', 'phoneNumber', 'email'} and
            caller.get('id') == 'main-stall-caller' and caller.get('displayName') == 'Main stall fixture' and
            all(caller.get(key) is None for key in ('avatarUrl', 'phoneNumber', 'email')),
            'public main-stall caller differs')
    return dict(success=True, mode='sdk-main-stall',
        classification='simulator direct real native-owner method with stalled main; not PushKit delivery, CKSimInjectPush, APNs or cold launch',
        owner=owner, fixtureID=fixture_id, conversationID=call, actualReports=1, actualSettlements=1,
        nativeCompletions=1, reportEntryBeforeNativeReturn=True, actualSettlementBeforeNativeCompletion=True,
        mainStallRuntimeMilliseconds=span_ms, mainStallElapsedSeconds=elapsed, canonicalPublicPayload=True)
