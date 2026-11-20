// Test-only timing and journal inputs for the Mac Inspector journey.
import { readFileSync, writeFileSync } from 'node:fs';
import { isRecord } from './json-fields.ts';
import { join } from 'node:path';
import { sha256, validate } from './runtime-package.ts';
import { isInspectorSession } from './inspector-journal.ts';

export const inspectorJourneyBudgetSeconds = 600;
export const inspectorUnansweredSeconds = inspectorJourneyBudgetSeconds + 60;

/** Changes only this disposable package's unanswered timeout, preserving checksum validation. */
export function configureInspectorFixture(runtime: string) {
  const info = validate(runtime);
  const name = 'profiles/ios-27.0.json';
  const profile: unknown = JSON.parse(readFileSync(join(runtime, name), 'utf8'));
  if (!isRecord(profile)) throw new Error('Invalid Inspector runtime profile');
  const bytes = JSON.stringify({ ...profile, ringTimeoutSeconds: inspectorUnansweredSeconds });
  writeFileSync(join(runtime, name), bytes);
  info.files[name] = sha256(bytes);
  writeFileSync(join(runtime, 'build-info.json'), JSON.stringify(info));
  validate(runtime);
}

/** Resolves the current invocation's on-disk journal before starting any timed UI steps. */
export function inspectorFixtureJournal(container: string) {
  const channel = join(container, 'Documents/.callkit-simulator');
  const session: unknown = JSON.parse(readFileSync(join(channel, 'session.json'), 'utf8'));
  if (!isInspectorSession(session) || session.bundleID !== 'dev.callkitsim.smoke') {
    throw new Error('Invalid Inspector fixture invocation');
  }
  return join(channel, session.runID, 'events.jsonl');
}
