"""Native LCK audio/dataflow regressions, with device and injected evidence kept distinct.

The delayed-unpause rule is an injected scheduler regression, not a newly measured
Apple timing guarantee. It preserves the device-observed End-active composition.
"""
import time

PREFIX = 'lck.fixture.'


def event(j, name, predicate=lambda row: True, *, start=0):
    return j.wait(lambda rows: next((r for r in rows[start:] if r['event'] == PREFIX + name and predicate(r)), None))


def audio_delay(j, settled, expected, description):
    j.app('advance', ms=expected - 1)
    assert not any(r['event'] == PREFIX + 'didActivate' for r in j.rows()), description + ' audio fired before its deadline'
    j.app('advance', ms=1)
    activated = event(j, 'didActivate')
    assert activated['sequence'] > settled['sequence'], description + ' audio preceded native fulfillment'
    delay = fixture_time(activated) - fixture_time(settled)
    assert delay == expected, f'{description} controlled audio after settlement: {delay}ms'
    print(f'LCK {description} controlled audio after settlement: {delay} ms', flush=True)
    return delay


def composite_audio(j, name, operation, delayed_kind):
    j.pair(name)
    j.app('clock')
    j.app('policy', rules={delayed_kind: dict(mode='delay', ms=2000, nth=1)})
    start = len(j.rows())
    action_ids = j.composite(operation)
    assert len(action_ids) == 2
    performed = [r for r in j.rows()[start:] if r['event'] == PREFIX + 'perform' and r.get('actionID') in action_ids]
    assert {(r['kind'], r['callUUID']) for r in performed} == {(delayed_kind, j.ids['A']), ('Join', j.ids['B'])}
    delayed = next(r for r in performed if r['kind'] == delayed_kind)
    fixture_time(delayed)
    j.app('advance', ms=1999)
    rows = j.rows()[start:]
    assert not any(r['event'] == PREFIX + 'settled' and r.get('actionID') == delayed['actionID'] for r in rows), 'delayed constituent settled early'
    assert not any(r['event'] == PREFIX + 'changed' and r.get('callUUID') == j.ids['B'] and r.get('state') == 'joined' for r in rows), 'accepted B joined before every constituent settled'
    assert not any(r['event'] == PREFIX + 'didActivate' for r in rows), 'composite reactivated audio before its last settlement'
    j.app('advance', ms=1)
    j.wait(lambda rows: action_ids <= {r.get('actionID') for r in rows[start:] if r['event'] == PREFIX + 'settled'})
    j.app('advance', ms=114)
    assert not any(r['event'] == PREFIX + 'didActivate' for r in j.rows()[start:]), 'composite audio fired before its deadline'
    j.app('advance', ms=1)
    rows = j.state(A='paused' if delayed_kind == 'Pause' else 'left', B='joined')
    settled = [r for r in rows[start:] if r['event'] == PREFIX + 'settled' and r.get('actionID') in action_ids]
    delayed_settlement = next(r for r in settled if r['actionID'] == delayed['actionID'])
    assert fixture_time(delayed_settlement) - fixture_time(delayed) == 2000, 'controlled constituent settlement must be exactly 2000ms'
    joined_settlement = next(r for r in settled if r['kind'] == 'Join')
    assert joined_settlement['sequence'] < delayed_settlement['sequence'], 'Join must settle while the other constituent remains pending'
    terminal_sequence = max(r['sequence'] for r in settled)
    joined = event(j, 'changed', lambda r: r.get('callUUID') == j.ids['B'] and r.get('state') == 'joined', start=start)
    assert joined['sequence'] > terminal_sequence, 'accepted B joined before every constituent settled'
    activated = event(j, 'didActivate', start=start)
    rows = j.rows()[start:]
    assert not any(r['event'] == PREFIX + 'didActivate' and r['sequence'] < terminal_sequence for r in rows), 'composite reactivated audio before its last settlement'
    assert activated['sequence'] > terminal_sequence
    assert any(r['event'] == PREFIX + 'didDeactivate' and r['sequence'] < activated['sequence'] for r in rows), 'native handoff must deactivate before activating'
    delay = fixture_time(activated) - max(fixture_time(r) for r in settled)
    assert delay == 115, 'composite audio must activate 115ms after final settlement'
    print(f'LCK {name} audio after last native settlement: {delay} ms', flush=True)
    return delay


def fixture_time(row):
    value = row.get('fixtureTimeMS')
    assert type(value) is int, 'controlled fixture clock evidence is required'
    return value


def run_mute_case(j):
    j.begin('mutePreservesPendingJoinAudio')
    j.app('incoming', call='A')
    j.app('clock')
    action_ids = set(j.system('answer', call='A')['actionIDs'])
    joined = event(j, 'settled', lambda r: r.get('actionID') in action_ids and r['kind'] == 'Join')
    fixture_time(joined)
    j.app('advance', ms=180)
    assert not any(r['event'] == PREFIX + 'didActivate' for r in j.rows()), 'Mute stimulus missed the pending Join audio window'
    mute_ids = set(j.system('mute', call='A', muted=True)['actionIDs'])
    muted = event(j, 'perform', lambda r: r.get('actionID') in mute_ids and r['kind'] in ('Mute', 'MuteConversationAction'))
    mute_settlement = event(j, 'settled', lambda r: r.get('actionID') == muted['actionID'])
    delivery_ms = fixture_time(muted) - fixture_time(joined)
    assert delivery_ms == 180, f'controlled Mute delivery was {delivery_ms}ms'
    j.app('advance', ms=109)
    assert not any(r['event'] == PREFIX + 'didActivate' for r in j.rows()), 'Join audio fired before its original deadline'
    j.app('advance', ms=1)
    activated = event(j, 'didActivate')
    assert joined['sequence'] < muted['sequence'] < mute_settlement['sequence'] < activated['sequence'], 'Mute must settle while the original Join audio remains pending'
    join_audio_ms = fixture_time(activated) - fixture_time(joined)
    after_mute_ms = fixture_time(activated) - fixture_time(mute_settlement)
    assert join_audio_ms == 290, f'Mute changed the original Join audio deadline: {join_audio_ms}ms'
    assert after_mute_ms == 110, f'Mute restarted the pending Join audio timer: {after_mute_ms}ms'
    j.app('advance', ms=350)
    assert len([r for r in j.rows() if r['event'] == PREFIX + 'didActivate']) == 1, 'Mute caused duplicate audio activation'
    assert not any(r['event'] == PREFIX + 'didDeactivate' for r in j.rows()), 'Mute unexpectedly deactivated audio'
    print(f'LCK controlled Mute delivery: {delivery_ms} ms; Join audio: {join_audio_ms} ms; audio after Mute: {after_mute_ms} ms', flush=True)
    return dict(joinToMuteDeliveryMS=delivery_ms,
                joinToMuteSettlementMS=fixture_time(mute_settlement) - fixture_time(joined),
                joinToAudioMS=join_audio_ms, muteSettlementToAudioMS=after_mute_ms,
                timingEvidence='controlled fixture clock; not device measurements')


def run_resume_case(j):
    j.pair('delayedResumeEndsActive')
    handoff_start = len(j.rows())
    j.composite()
    j.state(A='paused', B='joined')
    event(j, 'didActivate', start=handoff_start)
    j.app('clock')
    j.app('policy', rules={'Pause': dict(mode='delay', ms=300, nth=1)})
    resume_start = len(j.rows())
    j.app('pause', call='A', paused=False)
    resumed = event(j, 'perform', lambda r: r['kind'] == 'Pause' and r['callUUID'] == j.ids['A'] and r.get('held') is False, start=resume_start)
    fixture_time(resumed)
    j.app('advance', ms=299)
    rows = j.rows()[resume_start:]
    assert not any(r['event'] == PREFIX + 'settled' and r.get('actionID') == resumed['actionID'] for r in rows), 'Resume settled before its injected delay'
    assert not any(r['event'] == PREFIX + 'perform' and r.get('kind') == 'End' and r.get('callUUID') == j.ids['B'] for r in rows), 'End B arrived before delayed Resume A settled'
    j.app('advance', ms=1)
    settled = event(j, 'settled', lambda r: r.get('actionID') == resumed['actionID'], start=resume_start)
    assert settled.get('policy') == 'delay' and settled.get('failed') is False
    fulfillment_delay = fixture_time(settled) - fixture_time(resumed)
    assert fulfillment_delay == 300, f'controlled Resume fixture delay was {fulfillment_delay}ms'
    ended = event(j, 'perform', lambda r: r['kind'] == 'End' and r['callUUID'] == j.ids['B'], start=resume_start)
    assert ended['sequence'] > settled['sequence'], 'system End B arrived before delayed Resume A settled'
    after_settlement = fixture_time(ended) - fixture_time(settled)
    assert after_settlement == 0, f'elapsed resume delay was not clamped to zero: {after_settlement}ms'
    observed_b = [r['kind'] for r in j.rows()[resume_start:] if r['event'] == PREFIX + 'perform' and r['callUUID'] == j.ids['B']]
    assert observed_b == ['End'], 'resuming A must end active B, without a Pause B'
    j.state(A='joined', B='left')
    return fulfillment_delay, after_settlement


def run_cases(j):
    j.begin('singleJoinAudio')
    j.app('incoming', call='A')
    j.app('clock')
    action_ids = set(j.system('answer', call='A')['actionIDs'])
    assert len(action_ids) == 1, 'single Join must contain exactly one runtime action'
    settled = event(j, 'settled', lambda r: r.get('actionID') in action_ids and r['kind'] == 'Join')
    j.state(A='joined')
    # Keep the shipping single-Join schedule distinct from the composite path;
    # fixture time catches an accidentally immediate activation.
    join_audio_delay = audio_delay(j, settled, 290, 'single Join')

    j.begin('singleStartAudio')
    j.app('clock')
    j.app('start', call='A')
    started = event(j, 'perform', lambda r: r['kind'] == 'Start' and r['callUUID'] == j.ids['A'])
    settled = event(j, 'settled', lambda r: r.get('actionID') == started['actionID'])
    start_audio_delay = audio_delay(j, settled, 230, 'single Start')

    mute_timings = run_mute_case(j)

    hold_audio_delay = composite_audio(j, 'delayedPauseCompositeAudio', 'hold-and-accept', 'Pause')
    end_audio_delay = composite_audio(j, 'delayedEndCompositeAudio', 'end-and-accept', 'End')

    fulfillment_delay, after_settlement = run_resume_case(j)
    print(f'LCK delayed unpause fulfillment: {fulfillment_delay} ms; End B after settlement: {after_settlement} ms', flush=True)
    j.save()
    return dict(singleJoinAudioMS=join_audio_delay, singleStartAudioMS=start_audio_delay,
                singleAudioTimingEvidence='controlled fixture clock; not device measurements',
                mutePreservedJoinAudioMS=mute_timings['joinToAudioMS'], muteTimings=mute_timings, delayedPauseCompositeAudioMS=hold_audio_delay,
                delayedEndCompositeAudioMS=end_audio_delay, compositeAudioTimingEvidence='controlled fixture clock; not device measurements', delayedResumeMS=fulfillment_delay,
                endAfterResumeSettlementMS=after_settlement, delayedResumeEvidence='injected scheduler regression')
