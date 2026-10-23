import bridge, { ChangeEvent } from './modules/expo2-spike';

export type Result = {
  id: string;
  pass: boolean;
  values: Record<string, unknown>;
  threads: unknown[];
};

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

export async function runDemonstrations(): Promise<Result[]> {
  const results: Result[] = [];
  try {
    const initial = bridge.snapshot;
    assert(initial.version === 0, 'Initial version');
    assert(initial === bridge.snapshot, 'Stable cached JS identity');
    const [ringing, active] = initial.conversations;
    assert(
      ringing?.status === 'ringing' &&
        ringing.id === 'ring-1' &&
        ringing.caller === 'Ada',
      'Ringing union',
    );
    assert(
      active?.status === 'active' &&
        active.id === 'active-1' &&
        active.connectedAt === 123,
      'Active union',
    );
    assert(
      Object.isFrozen(initial) &&
        Object.isFrozen(initial.conversations) &&
        initial.conversations.every(Object.isFrozen),
      'Deeply frozen projection',
    );
    results.push({
      id: 'snapshot',
      pass: true,
      values: { initial, stableIdentity: true, frozen: true },
      threads: [],
    });
  } catch (error) {
    results.push({
      id: 'snapshot',
      pass: false,
      values: { error: String(error) },
      threads: [],
    });
  }
  const events: ChangeEvent[] = [];
  const subscription = bridge.addListener('change', (event) =>
    events.push(event),
  );
  try {
    const initial = bridge.snapshot;
    [1, 1, 2, 2, 3].forEach((version) => bridge.publish(version));
    await bridge.drainChanges();
    assert(
      events.length === 1 && events[0].version === 3,
      'One coalesced event at latest version',
    );
    assert(
      events[0].snapshot === bridge.snapshot,
      'Event uses published cached object',
    );
    assert(
      initial.version === 0 && initial !== bridge.snapshot,
      'Previous snapshot immutable',
    );
    bridge.publish(3);
    await bridge.drainChanges();
    assert(events.length === 1, 'Duplicate version emits nothing');
    bridge.publish(4);
    await bridge.drainChanges();
    assert(
      Number(events.length) === 2 && events[1].version === 4,
      'Next version emits once',
    );
    results.push({
      id: 'change-event',
      pass: true,
      values: {
        versions: events.map((event) => event.version),
        stableEventIdentity: true,
      },
      threads: [],
    });
  } catch (error) {
    results.push({
      id: 'change-event',
      pass: false,
      values: {
        error: String(error),
        versions: events.map((event) => event.version),
      },
      threads: [],
    });
  } finally {
    subscription.remove();
  }
  await bridge.writeResults(JSON.stringify(results));
  return results;
}
