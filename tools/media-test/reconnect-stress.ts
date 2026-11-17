import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runBuild } from './build-timeout.ts';

/** Repeats the normal parallel tool suite; any failure ends qualification immediately. */
export async function reconnectStress(directory: string, iterations = 30): Promise<void> {
  if (!Number.isSafeInteger(iterations) || iterations < 1 || iterations > 30) throw Error('Invalid stress count');
  const original = process.env.MEDIA_SERVER_TRACE_DIRECTORY;
  const results: { iteration: number; code: number; startedAt: string; elapsedMs: number }[] = [];
  mkdirSync(directory, { recursive: true });
  const priorDirectory = process.cwd();
  try {
    process.chdir(fileURLToPath(new URL('..', import.meta.url)));
    for (let iteration = 1; iteration <= iterations; iteration++) {
      const evidence = join(directory, `iteration-${iteration}`);
      mkdirSync(evidence, { recursive: true }); process.env.MEDIA_SERVER_TRACE_DIRECTORY = evidence;
      const startedAt = new Date().toISOString(), start = performance.now();
      console.log(JSON.stringify({ kind: 'reconnect-stress', iteration, iterations, state: 'started' }));
      const code = await runBuild({ command: process.execPath, args: ['--test'], timeoutMS: 180_000,
        directory: evidence, capture: async () => {} });
      results.push({ iteration, code, startedAt, elapsedMs: performance.now() - start });
      writeFileSync(join(directory, 'summary.json'), JSON.stringify({ iterations, results }, null, 2) + '\n');
      if (code !== 0) throw Error(`Parallel suite failed at iteration ${iteration}; no test was retried`);
    }
  } finally {
    process.chdir(priorDirectory);
    if (original === undefined) delete process.env.MEDIA_SERVER_TRACE_DIRECTORY;
    else process.env.MEDIA_SERVER_TRACE_DIRECTORY = original;
  }
}
if (import.meta.main) {
  const [directory, count] = process.argv.slice(2);
  if (!directory) throw Error('Usage: reconnect-stress.ts <evidence-directory> [1-30]');
  await reconnectStress(resolve(directory), count === undefined ? 30 : Number(count));
}
