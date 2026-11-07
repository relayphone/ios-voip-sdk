import { readFileSync } from 'node:fs';
import { isMain, main } from './command.ts';

/** The #266 retry rule: no failed tests, and a runner that hung before connecting. */
export function runnerHungBeforeConnecting(summary: string, log: string): boolean {
  const count: unknown = (JSON.parse(summary) as { failedTests?: unknown }).failedTests;
  return Number.isSafeInteger(count) && Number(count) === 0
    && log.includes('hung before establishing connection');
}

if (isMain(import.meta.url)) {
  await main(() => {
    const [summary, log] = process.argv.slice(2);
    if (!summary || !log) throw new Error('Usage: simulator-test-result.ts <summary.json> <test.log>');
    if (!runnerHungBeforeConnecting(readFileSync(summary, 'utf8'), readFileSync(log, 'utf8'))) {
      process.exitCode = 1;
    }
  });
}
