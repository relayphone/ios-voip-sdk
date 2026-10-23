import bridge, { ThreadSample } from './modules/expo2-spike';
import type { Result } from './demonstrations';

export async function runHazard(): Promise<Result> {
  const threads: ThreadSample[] = [];
  let observation: Record<string, unknown>;
  bridge.resetHazard();
  try {
    const trials = await Promise.allSettled(
      Array.from({ length: 64 }, () => bridge.hazardIncrement(false)),
    );
    const racy = trials.flatMap((trial) =>
      trial.status === 'fulfilled' ? [trial.value] : [],
    );
    threads.push(...racy);
    const count = bridge.hazardCount(false);
    observation = {
      calls: 64,
      completed: racy.length,
      errors: trials.flatMap((trial) =>
        trial.status === 'rejected' ? [String(trial.reason)] : [],
      ),
      offJS: racy.filter((sample) => !sample.isOnJavaScriptThread).length,
      finalCount: count,
      lost: count !== 64,
    };
  } catch (error) {
    observation = { error: String(error) };
  }
  try {
    const scheduled = await Promise.all(
      Array.from({ length: 64 }, () => bridge.hazardIncrement(true)),
    );
    threads.push(...scheduled);
    const count = bridge.hazardCount(true);
    const offJS = scheduled.filter(
      (sample) => !sample.isOnJavaScriptThread,
    ).length;
    if (offJS !== 0 || count !== 64 || scheduled.length !== 64)
      throw new Error(
        'Scheduled increments must all run on JS and count exactly 64',
      );
    return {
      id: 'actor-hazard',
      pass: true,
      values: {
        observation,
        scheduled: { calls: 64, offJS, finalCount: count },
      },
      threads,
    };
  } catch (error) {
    return {
      id: 'actor-hazard',
      pass: false,
      values: { observation, error: String(error) },
      threads,
    };
  }
}
