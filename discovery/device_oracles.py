"""Small evidence-derived expectations shared by live conformance checks."""
import collections
import math

from summarize import require

# These are qualification tolerances, not measured Apple deadline values.
# timeoutIn is sampled when the delegate runs and rounded to tenths by the
# probe. We permit up to 2 s scheduling delay from the largest device sample;
# this chosen tolerance is not a measurement of Apple's delivery jitter.
DEADLINE_DELIVERY_JITTER_SECONDS = 2.0
DEADLINE_ROUNDING_SECONDS = 0.1


def deadline_bands(reference):
    samples = collections.defaultdict(list)
    for row in reference:
        if row['event'] not in ('tap.perform', 'provider.perform'):
            continue
        kind, seconds = row.get('kind'), row.get('timeoutIn')
        require(isinstance(kind, str) and kind, 'missing device deadline action kind')
        require(type(seconds) in (int, float) and math.isfinite(seconds) and seconds > 0,
                f'{kind}: missing or invalid device deadline')
        samples[kind].append(seconds)
    require(samples, 'missing device action deadlines')
    bands = {}
    for kind, values in samples.items():
        require(max(values) - min(values) <= DEADLINE_DELIVERY_JITTER_SECONDS,
                f'{kind}: ambiguous device deadlines')
        bands[kind] = (max(values) - DEADLINE_DELIVERY_JITTER_SECONDS,
                       max(values) + DEADLINE_ROUNDING_SECONDS)
    return bands


def check_deadline(action, bands):
    kind, seconds = action.get('kind'), action.get('timeoutIn')
    require(kind in bands, f'{kind}: missing device deadline')
    low, high = bands[kind]
    require(type(seconds) in (int, float) and math.isfinite(seconds) and low <= seconds <= high,
            f'{kind}: action deadline differs from device [{low}, {high}]')


def d5_compositions(reference):
    """Read successful system-UI transactions, including their target call roles."""
    windows = {
        'hold-and-accept': ('2-hold-and-accept', 'after-hold-and-accept', 'B answered'),
        'end-and-accept': ('3-end-and-accept', 'after-end-and-accept', 'C answered'),
        'decline': ('4-decline-waiting', 'after-decline', 'D ended'),
    }
    result = {}
    for operation, (phase, snapshot, outcome) in windows.items():
        starts = [i for i, row in enumerate(reference) if row['event'] == 'phase' and row['name'] == phase]
        ends = [i for i, row in enumerate(reference)
                if row['event'] == 'observer.snapshot' and row['label'] == snapshot]
        require(len(starts) == len(ends) == 1 and starts[0] < ends[0],
                f'{operation}: missing or ambiguous device phase/outcome')
        start, end = starts[0], ends[0]
        require(sum(row['event'] == 'wait.met' and row['label'] == outcome for row in reference[start:end]) == 1
                and not any(row['event'] == 'wait.timeout' for row in reference[start:end]),
                f'{operation}: unsuccessful device outcome')
        transactions = [i for i in range(start, end) if reference[i]['event'] == 'provider.executeTransaction']
        require(len(transactions) == 1, f'{operation}: missing or ambiguous device transaction')
        transaction = transactions[0]
        state = {}
        for row in reference[:transaction]:
            if row['event'] == 'observer.callChanged':
                state[row['uuid']] = row
        active = [identity for identity, call in state.items()
                  if not call['ended'] and call['connected'] and not call['held']]
        waiting = [identity for identity, call in state.items() if not call['ended'] and not call['connected']]
        require(len(active) == len(waiting) == 1, f'{operation}: ambiguous device call roles')
        roles = {active[0]: 'active', waiting[0]: 'waiting'}
        actions = [row for row in reference[transaction + 1:end] if row['event'] == 'provider.perform']
        require(actions and [row['kind'] for row in actions] == reference[transaction]['actions'],
                f'{operation}: device execute/perform mismatch')
        require(len({row['id'] for row in actions}) == len(actions), f'{operation}: duplicate device action')
        result[operation] = []
        for action in actions:
            require(action['call'] in roles, f'{operation}: unknown device call role')
            signature = dict(kind=action['kind'], role=roles[action['call']])
            if 'onHold' in action:
                require(type(action['onHold']) is bool, f'{operation}: invalid device hold value')
                signature['onHold'] = action['onHold']
            result[operation].append(signature)
    return result


def check_d5_composition(operation, expected, action_ids, call_roles, engine, probe):
    """Bind one CLI receipt to its journal transaction and delegate actions."""
    transactions = [row for row in engine if row['event'] == 'transaction.delivered'
                    and row['actionIDs'] == action_ids]
    require(len(transactions) == 1, f'{operation}: missing or ambiguous CLI transaction')
    require(transactions[0]['kinds'] == [row['kind'] for row in expected],
            f'{operation}: composition differs from device')
    prefixes = [identity[:8] for identity in action_ids]
    require(len(set(prefixes)) == len(prefixes), f'{operation}: ambiguous action prefixes')
    actions = [row for row in probe if row['event'] == 'provider.perform' and row['id'] in prefixes]
    require([row['id'] for row in actions] == prefixes, f'{operation}: delegate action order/identity differs')
    actual = []
    for action in actions:
        require(action['call'] in call_roles, f'{operation}: unknown CLI call target')
        signature = dict(kind=action['kind'], role=call_roles[action['call']])
        if 'onHold' in action: signature['onHold'] = action['onHold']
        actual.append(signature)
    require(actual == expected, f'{operation}: delegate composition differs from device')
