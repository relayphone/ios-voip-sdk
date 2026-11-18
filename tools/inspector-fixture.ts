// Test-only timing and journal inputs for the Mac Inspector journey.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { sha256, validate } from './runtime-package.ts';

export const inspectorJourneyBudgetSeconds = 600;
export const inspectorUnansweredSeconds = inspectorJourneyBudgetSeconds + 60;

/** Changes only this disposable package's unanswered timeout, preserving checksum validation. */
export function configureInspectorFixture(runtime: string): void {
  const info = validate(runtime);
  const name = 'profiles/ios-27.0.json';
  const profile = JSON.parse(readFileSync(join(runtime, name), 'utf8')) as { ringTimeoutSeconds: number };
  profile.ringTimeoutSeconds = inspectorUnansweredSeconds;
  const bytes = JSON.stringify(profile);
  writeFileSync(join(runtime, name), bytes);
  info.files[name] = sha256(bytes);
  writeFileSync(join(runtime, 'build-info.json'), JSON.stringify(info));
  validate(runtime);
}

/** Resolves the current invocation's on-disk journal before starting any timed UI steps. */
export function inspectorFixtureJournal(container: string): string {
  const channel = join(container, 'Documents/.callkit-simulator');
  const session = JSON.parse(readFileSync(join(channel, 'session.json'), 'utf8')) as {
    schemaVersion: number; bundleID: string; runID: string;
  };
  if (session.schemaVersion !== 1 || session.bundleID !== 'dev.callkitsim.smoke'
    || typeof session.runID !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(session.runID)) {
    throw new Error('Invalid Inspector fixture invocation');
  }
  return join(channel, session.runID, 'events.jsonl');
}
