"""Native LCK audio/dataflow regressions, with device and injected evidence kept distinct.

The delayed-unpause rule is an injected scheduler regression, not a newly measured
Apple timing guarantee. It preserves the device-observed End-active composition.
"""
import time

PREFIX = 'lck.fixture.'


def event(j, name, predicate=lambda row: True, *, start=0):
    return j.wait(lambda rows: next((r for r in rows[start:] if r['event'] == PREFIX + name and predicate(r)), None))


def audio_delay(j, settled, low, description):
    activated = event(j, 'didActivate')
    assert activated['sequence'] > settled['sequence'], description + ' audio preceded native fulfillment'
    delay = activated['t_ms'] - settled['t_ms']
    assert low <= delay <= 1000, f'{description} audio after settlement: {delay}ms'
    print(f'LCK {description} audio after settlement: {delay} ms', flush=True)
    return delay


def composite_audio(j, name, operation, delayed_kind):
    j.pair(name)
    j.app('policy', rules={delayed_kind: dict(mode='delay', ms=2000, nth=1)})
    start = len(j.rows())
    action_ids = j.composite(operation)
    assert len(action_ids) == 2
    performed = [r for r in j.rows()[start:] if r['event'] == PREFIX + 'perform' and r.get('actionID') in action_ids]
    assert {(r['kind'], r['callUUID']) for r in performed} == {(delayed_kind, j.ids['A']), ('Join', j.ids['B'])}
    delayed = next(r for r in performed if r['kind'] == delayed_kind)
    j.wait(lambda rows: action_ids <= {r.get('actionID') for r in rows[start:] if r['event'] == PREFIX + 'settled'})
    rows = j.state(A='paused' if delayed_kind == 'Pause' else 'left', B='joined')
    settled = [r for r in rows[start:] if r['event'] == PREFIX + 'settled' and r.get('actionID') in action_ids]
    delayed_settlement = next(r for r in settled if r['actionID'] == delayed['actionID'])
    assert 1900 <= delayed_settlement['t_ms'] - delayed['t_ms'] <= 5000, 'delayed constituent must really settle about 2s late'
    joined_settlement = next(r for r in settled if r['kind'] == 'Join')
    assert joined_settlement['sequence'] < delayed_settlement['sequence'], 'Join must settle while the other constituent remains pending'
    terminal_sequence = max(r['sequence'] for r in settled)
    joined = next(r for r in rows[start:] if r['event'] == PREFIX + 'changed' and r['callUUID'] == j.ids['B'] and r['state'] == 'joined')
    assert joined['sequence'] > terminal_sequence, 'accepted B joined before every constituent settled'
    activated = event(j, 'didActivate', start=start)
    rows = j.rows()[start:]
    assert not any(r['event'] == PREFIX + 'didActivate' and r['sequence'] < terminal_sequence for r in rows), 'composite reactivated audio before its last settlement'
    assert activated['sequence'] > terminal_sequence
    assert any(r['event'] == PREFIX + 'didDeactivate' and r['sequence'] < activated['sequence'] for r in rows), 'native handoff must deactivate before activating'
    delay = activated['t_ms'] - max(r['t_ms'] for r in settled)
    print(f'LCK {name} audio after last native settlement: {delay} ms', flush=True)
    return delay


def run_cases(j):
    j.begin('singleJoinAudio')
    j.app('incoming', call='A')
    action_ids = set(j.system('answer', call='A')['actionIDs'])
    assert len(action_ids) == 1, 'single Join must contain exactly one runtime action'
    settled = event(j, 'settled', lambda r: r.get('actionID') in action_ids and r['kind'] == 'Join')
    j.state(A='joined')
    # #85's first Join activates hundreds of ms after settlement. This budget
    # catches the composite-only path accidentally making it immediate.
    join_audio_delay = audio_delay(j, settled, 200, 'single Join')

    j.begin('singleStartAudio')
    j.app('start', call='A')
    started = event(j, 'perform', lambda r: r['kind'] == 'Start' and r['callUUID'] == j.ids['A'])
    settled = event(j, 'settled', lambda r: r.get('actionID') == started['actionID'])
    start_audio_delay = audio_delay(j, settled, 150, 'single Start')

    hold_audio_delay = composite_audio(j, 'delayedPauseCompositeAudio', 'hold-and-accept', 'Pause')
    end_audio_delay = composite_audio(j, 'delayedEndCompositeAudio', 'end-and-accept', 'End')

    j.pair('delayedResumeEndsActive')
    handoff_start = len(j.rows())
    j.composite()
    j.state(A='paused', B='joined')
    event(j, 'didActivate', start=handoff_start)
    j.app('policy', rules={'Pause': dict(mode='delay', ms=300, nth=1)})
    resume_start = len(j.rows())
    j.app('pause', call='A', paused=False)
    resumed = event(j, 'perform', lambda r: r['kind'] == 'Pause' and r['callUUID'] == j.ids['A'] and r.get('held') is False, start=resume_start)
    settled = event(j, 'settled', lambda r: r.get('actionID') == resumed['actionID'], start=resume_start)
    assert settled.get('policy') == 'delay' and settled.get('failed') is False
    fulfillment_delay = settled['t_ms'] - resumed['t_ms']
    assert 250 <= fulfillment_delay <= 1500, f'resume fixture delay was {fulfillment_delay}ms'
    ended = event(j, 'perform', lambda r: r['kind'] == 'End' and r['callUUID'] == j.ids['B'], start=resume_start)
    assert ended['sequence'] > settled['sequence'], 'system End B arrived before delayed Resume A settled'
    after_settlement = ended['t_ms'] - settled['t_ms']
    assert 0 <= after_settlement <= 150, f'elapsed resume delay was not clamped to zero: {after_settlement}ms'
    observed_b = [r['kind'] for r in j.rows()[resume_start:] if r['event'] == PREFIX + 'perform' and r['callUUID'] == j.ids['B']]
    assert observed_b == ['End'], 'resuming A must end active B, without a Pause B'
    j.state(A='joined', B='left')
    print(f'LCK delayed unpause fulfillment: {fulfillment_delay} ms; End B after settlement: {after_settlement} ms', flush=True)
    j.save()
    return dict(singleJoinAudioMS=join_audio_delay, singleStartAudioMS=start_audio_delay,
                delayedPauseCompositeAudioMS=hold_audio_delay,
                delayedEndCompositeAudioMS=end_audio_delay, delayedResumeMS=fulfillment_delay,
                endAfterResumeSettlementMS=after_settlement, delayedResumeEvidence='injected scheduler regression')
