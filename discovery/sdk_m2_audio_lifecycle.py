#!/usr/bin/env python3
"""Pure audio lifecycle capture gate; native identity binding belongs to M2."""
import uuid

from summarize import require

SCALARS = ('kind', 'hasSource', 'source', 'hasInterruptionReason', 'interruptionReason', 'shouldResume', 'phase')
BOOLEANS = ('hasSource', 'hasInterruptionReason', 'shouldResume')
MODERN_NOTIFICATIONS = {
    'active': 'AVAudioSessionDidBecomeActiveNotification',
    'inactive': 'AVAudioSessionDidBecomeInactiveNotification',
    'recommended': 'AVAudioSessionResumptionRecommendationNotification',
}
LEGACY_NOTIFICATION = 'AVAudioSessionInterruptionNotification'


def events(rows, name):
    return [row for row in rows if row.get('event') == name]


def single(rows, name, **fields):
    matches = [row for row in events(rows, name) if all(row.get(k) == v for k, v in fields.items())]
    require(len(matches) == 1, 'audio lifecycle: missing/duplicate ' + name + ' ' + str(fields))
    return matches[0]


def position(rows, target):
    return next(index for index, row in enumerate(rows) if row is target)


def strict(row, key, expected):
    return type(row.get(key)) is type(expected) and row[key] == expected


def valid_uuid(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)).upper() == value.upper()
    except (ValueError, AttributeError):
        return False


def validate_engine(engine):
    incoming = single(engine, 'report.incoming')
    call = incoming.get('callUUID')
    require(valid_uuid(call), 'audio lifecycle: incoming call identity missing')
    delivered = events(engine, 'transaction.delivered')
    kinds = ['CXAnswerCallAction', 'CXSetHeldCallAction', 'CXSetHeldCallAction', 'CXEndCallAction']
    require([row.get('kinds') for row in delivered] == [[kind] for kind in kinds] and
            all(type(row.get('actionIDs')) is list and len(row['actionIDs']) == 1 for row in delivered),
            'audio lifecycle: join/hold/resume/end transaction inventory differs')
    actions = [row['actionIDs'][0] for row in delivered]
    require(all(valid_uuid(action) for action in actions) and len({uuid.UUID(action) for action in actions}) == 4,
            'audio lifecycle: action identities missing or repeated')
    settled = events(engine, 'action.settled')
    require(len(settled) == 4 and [row.get('actionID') for row in settled] == actions and
            all(row.get('fulfilled') is True for row in settled), 'audio lifecycle: actions did not fulfill once in order')
    changes = events(engine, 'call.changed')
    require(changes and all(row.get('uuid') == call and row.get('outgoing') is False and
            all(type(row.get(key)) is bool for key in ('connected', 'held', 'ended')) for row in changes),
            'audio lifecycle: live call identity or booleans differ')
    audio = [row for row in engine if row.get('event') in ('audio.activated', 'audio.deactivated')]
    expected_audio = ['audio.activated', 'audio.deactivated', 'audio.activated', 'audio.deactivated']
    require([row['event'] for row in audio] == expected_audio, 'audio lifecycle: runtime activation inventory differs')
    states = [(True, False, False), (True, True, False), (True, False, False), (True, False, True)]
    for index, (transaction, settlement, native_audio, state) in enumerate(zip(delivered, settled, audio, states)):
        begin, end = position(engine, settlement), position(engine, delivered[index + 1]) if index < 3 else len(engine)
        require(position(engine, transaction) < begin < position(engine, native_audio) < end,
                'audio lifecycle: native audio did not follow the corresponding settled action')
        require(any(begin < position(engine, row) < end and
                    tuple(row[key] for key in ('connected', 'held', 'ended')) == state for row in changes),
                'audio lifecycle: settled action did not produce answer/held/resumed/ended call state')
    require(changes[-1]['ended'] is True and not events(engine, 'fault.audioSuppressed') and not events(engine, 'audio.failed'),
            'audio lifecycle: native call did not end with normal audio')
    return call


def validate_lifecycle(rows, engine, path):
    require(path in ('modern', 'legacy'), 'audio lifecycle: unknown requested path')
    marker = single(rows, 'lifecycle.path')
    evidence = 'native-session-lifecycle' if path == 'modern' else 'native-synthetic-legacy-wiring'
    require(marker.get('path') == path and marker.get('evidence') == evidence,
            'audio lifecycle: path/evidence scope differs')
    phases = ['initial', 'answer', 'hold', 'resume', 'end', 'fixture-app-activation', 'fixture-app-deactivation'] if path == 'modern' else [
        'initial', 'answer', 'legacy-began', 'legacy-ended', 'hold', 'resume', 'end']
    scoped = [row for row in rows if row.get('event', '').startswith('lifecycle.') and 'phase' in row]
    require(all(row['phase'] in phases for row in scoped) and
            [phases.index(row['phase']) for row in scoped] == sorted(phases.index(row['phase']) for row in scoped),
            'audio lifecycle: phase scope missing or reordered')
    observations = events(rows, 'lifecycle.observed')
    consumed = events(rows, 'lifecycle.consumed')
    require(observations and len(observations) == len(consumed), 'audio lifecycle: observer/consumer capture empty or unmatched')
    sequence = [row['event'] for row in rows if row.get('event') in ('lifecycle.observed', 'lifecycle.consumed')]
    require(sequence == ['lifecycle.observed', 'lifecycle.consumed'] * len(observations),
            'audio lifecycle: observer/consumer pairs reordered')
    for raw, decoded in zip(observations, consumed):
        require(raw.get('kind') in ('active', 'inactive', 'recommended') and
                isinstance(raw.get('phase'), str) and raw['phase'] and raw.get('observerMain') is True and
                all(type(raw.get(key)) is bool and type(decoded.get(key)) is bool for key in BOOLEANS) and
                all(type(raw.get(key)) is int and type(decoded.get(key)) is int for key in ('source', 'interruptionReason')) and
                all(type(raw.get(key)) is type(decoded.get(key)) and raw[key] == decoded[key] for key in SCALARS),
                'audio lifecycle: observer/consumer scalar mapping or main delivery differs')
        require(all(type(decoded.get(key)) is bool for key in ('authorizedBefore', 'authorizedAfter')),
                'audio lifecycle: authorization booleans missing')
        require(decoded['authorizedAfter'] is False if raw['kind'] == 'inactive' else
                decoded['authorizedAfter'] is decoded['authorizedBefore'],
                'audio lifecycle: inactive failed to revoke or advisory notification changed authorization')
        if raw['kind'] == 'inactive':
            require(any(row.get('event') == 'lifecycle.adapterAuthorization' and row.get('authorized') is False and
                        row.get('phase') == raw['phase'] for row in rows[position(rows, raw) + 1:position(rows, decoded)]),
                    'audio lifecycle: inactive did not synchronously revoke adapter authorization')
        if path == 'modern':
            require(raw.get('notificationName') == MODERN_NOTIFICATIONS[raw['kind']],
                    'audio lifecycle: modern notification name differs')
            if raw['kind'] == 'inactive':
                require(isinstance(raw.get('contextClass'), str) and bool(raw['contextClass']) and
                        raw['hasSource'] is True and raw['source'] == 1 and
                        raw['hasInterruptionReason'] is False and raw['interruptionReason'] == 0 and
                        raw['shouldResume'] is False,
                        'audio lifecycle: app deactivation context/source differs; system interruption not qualified')
            else:
                require(raw['hasSource'] is False and raw['source'] == 0 and
                        raw['hasInterruptionReason'] is False and raw['interruptionReason'] == 0 and
                        (raw['kind'] == 'recommended' or raw['shouldResume'] is False) and
                        (isinstance(raw.get('contextClass'), str) and bool(raw['contextClass'])
                         if raw['kind'] == 'recommended' else raw.get('contextClass') == ''),
                        'audio lifecycle: modern context fields differ')
        else:
            require(raw.get('notificationName') == LEGACY_NOTIFICATION and raw.get('contextClass') == '' and
                    raw['kind'] in ('inactive', 'recommended') and raw['hasSource'] is False and raw['source'] == 0,
                    'audio lifecycle: legacy synthetic notification/context differs')
    pairs = {(raw['phase'], raw['kind']): (raw, decoded) for raw, decoded in zip(observations, consumed)}
    def pair(phase, kind):
        require(sum(raw['phase'] == phase and raw['kind'] == kind for raw in observations) == 1,
                'audio lifecycle: missing/duplicate required notification ' + phase)
        return pairs[(phase, kind)]
    delegates = events(rows, 'lifecycle.lckDelegate')
    expected = [(True, 1, 'answer'), (False, 1, 'hold'), (True, 2, 'resume'), (False, 2, 'end')]
    require(len(delegates) == 4 and all(strict(row, 'active', active) and strict(row, 'count', count) and
            row.get('phase') == phase for row, (active, count, phase) in zip(delegates, expected)),
            'audio lifecycle: genuine LCK delegate inventory differs')
    authorizations = events(rows, 'lifecycle.adapterAuthorization')
    require(authorizations and all(type(row.get('authorized')) is bool for row in authorizations) and
            [row.get('phase') for row in authorizations if row['authorized']] == ['answer', 'resume'] and
            all(row.get('phase') in ('initial', 'answer', 'legacy-began', 'legacy-ended', 'hold', 'resume', 'end',
                                    'fixture-app-activation', 'fixture-app-deactivation') for row in authorizations),
            'audio lifecycle: unexpected adapter authorization outside answer/resume')
    handlers = events(rows, 'lifecycle.handler')
    require([(row.get('kind'), row.get('phase')) for row in handlers] ==
            [('join', 'answer'), ('hold', 'hold'), ('hold', 'resume'), ('end', 'end')],
            'audio lifecycle: handler journey differs')
    if path == 'modern':
        required = [('answer', 'active'), ('hold', 'inactive'), ('resume', 'active'), ('end', 'inactive'),
                    ('fixture-app-activation', 'active'), ('fixture-app-deactivation', 'inactive')]
        required_pairs = [pair(phase, kind) for phase, kind in required]
        require([position(rows, raw) for raw, _ in required_pairs] == sorted(position(rows, raw) for raw, _ in required_pairs),
                'audio lifecycle: required native notifications reordered')
        require(not events(rows, 'lifecycle.syntheticPost'), 'audio lifecycle: modern path contains synthetic notifications')
        empty = single(rows, 'lifecycle.noConversations')
        requests = events(rows, 'lifecycle.fixtureSessionRequest')
        require(strict(empty, 'count', 0) and empty.get('phase') == 'end' and len(requests) == 2 and
                strict(requests[0], 'active', True) and requests[0].get('phase') == 'fixture-app-activation' and
                strict(requests[1], 'active', False) and requests[1].get('phase') == 'fixture-app-deactivation' and
                position(rows, required_pairs[3][1]) < position(rows, empty) < position(rows, requests[0]) <
                position(rows, required_pairs[4][0]) < position(rows, required_pairs[4][1]) < position(rows, requests[1]) <
                position(rows, required_pairs[5][0]) and position(rows, delegates[-1]) < position(rows, empty),
                'audio lifecycle: ordinary-session fixture not scoped after all conversations ended')
        require(all(decoded['authorizedBefore'] is False and decoded['authorizedAfter'] is False
                    for _, decoded in required_pairs[4:]), 'audio lifecycle: fixture activation restored authorization')
    else:
        posts = events(rows, 'lifecycle.syntheticPost')
        require([(row.get('kind'), row.get('phase')) for row in posts] ==
                [('inactive', 'legacy-began'), ('recommended', 'legacy-ended')] and
                not events(rows, 'lifecycle.fixtureSessionRequest') and not events(rows, 'lifecycle.noConversations'),
                'audio lifecycle: synthetic legacy scope differs')
        began, ended = pair('legacy-began', 'inactive'), pair('legacy-ended', 'recommended')
        require(position(rows, posts[0]) < position(rows, began[0]) < position(rows, began[1]) < position(rows, posts[1]) <
                position(rows, ended[0]) < position(rows, ended[1]) and began[1]['authorizedBefore'] is True and
                began[1]['authorizedAfter'] is False and ended[1]['authorizedBefore'] is False and
                ended[1]['authorizedAfter'] is False and began[0]['hasInterruptionReason'] is True and
                began[0]['interruptionReason'] == 0 and began[0]['shouldResume'] is False and
                ended[0]['hasInterruptionReason'] is False and ended[0]['interruptionReason'] == 0 and
                ended[0]['shouldResume'] is True,
                'audio lifecycle: legacy interruption/recommendation decoding or authorization differs')
    completed = single(rows, 'lifecycle.completed')
    require(strict(completed, 'authorized', False) and strict(completed, 'activations', 2) and
            strict(completed, 'deactivations', 2) and strict(completed, 'observedCount', len(observations)) and
            strict(completed, 'consumedCount', len(consumed)) and
            completed.get('phase') == ('fixture-app-deactivation' if path == 'modern' else 'end') and
            position(rows, completed) > max(position(rows, consumed[-1]), position(rows, delegates[-1])),
            'audio lifecycle: final authorization or capture counts differ')
    require([row for row in rows if row.get('event', '').startswith('lifecycle.')][-1] is completed,
            'audio lifecycle: events continued after final authorization checkpoint')
    call = validate_engine(engine)
    return dict(success=True, path=path, evidence=evidence, conversationID=call, observedCount=len(observations),
                consumedCount=len(consumed), lckActivations=2, lckDeactivations=2,
                systemInterruptionMeasured=False)
