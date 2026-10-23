import bridge, { ThreadSample } from './modules/expo2-spike';
import type { Result } from './demonstrations';

function check(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function backgroundEvent(): Promise<{
  emitter: ThreadSample;
  listener: ThreadSample;
}> {
  return new Promise((resolve, reject) => {
    const subscription = bridge.addListener('background', (emitter) => {
      clearTimeout(deadline);
      subscription.remove();
      try {
        resolve({
          emitter,
          listener: bridge.threadSample('event-js-listener'),
        });
      } catch (error) {
        reject(error);
      }
    });
    const deadline = setTimeout(() => {
      subscription.remove();
      reject(new Error('Background event deadline'));
    }, 5000);
    try {
      bridge.emitFromBackground();
    } catch (error) {
      clearTimeout(deadline);
      subscription.remove();
      reject(error);
    }
  });
}

export async function runThreading(): Promise<Result[]> {
  const results: Result[] = [];
  const threads: ThreadSample[] = [];
  try {
    const sync = bridge.threadSample('sync-entry');
    threads.push(sync);
    check(
      sync.isOnJavaScriptThread && !sync.isMainThread,
      'Sync @JS entry is on JS, off main',
    );
    const defaults = await bridge.defaultProbe();
    threads.push(...defaults);
    check(
      defaults.length === 2 &&
        defaults[0].phase === 'default-before-await' &&
        defaults[1].phase === 'default-after-await',
      'Both async suspension points captured',
    );
    check(
      defaults[0].threadID === sync.threadID &&
        defaults[0].isOnJavaScriptThread,
      'Default async entry starts on JS',
    );
    const first = await bridge.sdkProbe();
    threads.push(...first.threads);
    const concurrent = await Promise.all(
      Array.from({ length: 8 }, () => bridge.sdkProbe()),
    );
    const sequences = [first, ...concurrent]
      .map((reply) => reply.sequence)
      .sort((a, b) => a - b);
    check(
      sequences.join(',') === '1,2,3,4,5,6,7,8,9',
      'SDK actor serializes command state',
    );
    check(
      [first, ...concurrent].every(
        (reply) =>
          reply.threads.length === 2 &&
          reply.threads.every(
            (sample) => !sample.isOnJavaScriptThread && !sample.isMainThread,
          ),
      ),
      'SDK actor bodies run off JS/main',
    );
    const event = await backgroundEvent();
    threads.push(event.emitter, event.listener);
    check(
      !event.emitter.isOnJavaScriptThread &&
        !event.emitter.isMainThread &&
        event.emitter.queueLabel === 'expo2.spike.background-event',
      'Native event emitted from named background queue',
    );
    check(
      event.listener.isOnJavaScriptThread &&
        event.listener.threadID === sync.threadID,
      'Event listener returns to JS',
    );
    check(
      threads.every(
        (sample) =>
          /^\d+$/.test(sample.threadID) &&
          !sample.isMainThread &&
          sample.supportsAsyncScheduling &&
          sample.isOnJavaScriptThread === (sample.threadID === sync.threadID) &&
          Boolean(sample.threadName || sample.queueLabel),
      ),
      'Runtime predicate, pthread identity, and thread diagnostics agree',
    );
    results.push({
      id: 'threading',
      pass: true,
      values: {
        actorSequences: sequences,
        asyncAfterAwaitOnJS: defaults[1].isOnJavaScriptThread,
      },
      threads,
    });
  } catch (error) {
    results.push({
      id: 'threading',
      pass: false,
      values: { error: String(error) },
      threads,
    });
  }
  const benchmarkThreads: ThreadSample[] = [];
  try {
    const measurements = [];
    for (const size of [2, 2048]) {
      bridge.configureFixture(size);
      await bridge.drainChanges();
      const snapshot = bridge.snapshot;
      check(snapshot.conversations.length === size, 'Benchmark fixture size');
      for (let index = 0; index < 100; index++)
        check(bridge.snapshot === snapshot, 'Warm cache identity');
      benchmarkThreads.push(bridge.threadSample(`snapshot-benchmark-${size}`));
      const samples = new Float64Array(1000);
      let stable = true;
      const batchStart = performance.now();
      for (let index = 0; index < samples.length; index++) {
        const start = performance.now();
        const value = bridge.snapshot;
        const end = performance.now();
        samples[index] = (end - start) * 1000;
        stable = stable && value === snapshot;
      }
      const totalMs = performance.now() - batchStart;
      const sorted = Array.from(samples).sort((a, b) => a - b);
      check(
        stable && sorted.every((value) => Number.isFinite(value) && value >= 0),
        'Valid timings and constant snapshot identity',
      );
      measurements.push({
        conversations: size,
        reads: samples.length,
        warmupReads: 100,
        unit: 'microseconds',
        p50: sorted[499],
        p99: sorted[989],
        totalMs,
      });
    }
    check(
      benchmarkThreads.every(
        (sample) => sample.isOnJavaScriptThread && !sample.isMainThread,
      ),
      'Benchmark ran on JS thread',
    );
    results.push({
      id: 'snapshot-benchmark',
      pass: true,
      values: { measurements },
      threads: benchmarkThreads,
    });
  } catch (error) {
    results.push({
      id: 'snapshot-benchmark',
      pass: false,
      values: { error: String(error) },
      threads: benchmarkThreads,
    });
  }
  return results;
}
