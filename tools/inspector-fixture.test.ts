import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { configureInspectorFixture, inspectorFixtureJournal, inspectorJourneyBudgetSeconds, inspectorUnansweredSeconds } from './inspector-fixture.ts';
import { manifest, requiredFiles, validate } from './runtime-package.ts';

test('the disposable fixture outlives the UI budget while preserving other profile inputs and package integrity', () => {
  const runtime = mkdtempSync(join(tmpdir(), 'inspector-fixture-'));
  try {
    mkdirSync(join(runtime, 'profiles'));
    for (const name of requiredFiles) writeFileSync(join(runtime, name), name === 'VERSION' ? '0.1.2' : 'fixture');
    const profile = { ringTimeoutSeconds: 60.1, answerDeadlineSeconds: 30, evidence: ['measured'] };
    writeFileSync(join(runtime, 'profiles/ios-27.0.json'), JSON.stringify(profile));
    writeFileSync(join(runtime, 'build-info.json'), JSON.stringify({
      schemaVersion: 1, version: '0.1.2', files: manifest(runtime),
    }));
    const original = validate(runtime);
    configureInspectorFixture(runtime);
    const configured = validate(runtime);
    assert.ok(inspectorUnansweredSeconds > inspectorJourneyBudgetSeconds);
    assert.equal(inspectorJourneyBudgetSeconds, 600);
    assert.deepEqual(JSON.parse(readFileSync(join(runtime, 'profiles/ios-27.0.json'), 'utf8')),
      { ...profile, ringTimeoutSeconds: inspectorUnansweredSeconds });
    for (const name of requiredFiles.filter(name => name !== 'profiles/ios-27.0.json')) {
      assert.equal(configured.files[name], original.files[name]);
    }
    writeFileSync(join(runtime, 'CKSimRuntime.dylib'), 'corrupted');
    assert.throws(() => configureInspectorFixture(runtime), /checksum mismatch/);
  } finally { rmSync(runtime, { recursive: true, force: true }); }
});

test('the report observation uses the current fixture invocation and rejects other or escaping identities', () => {
  const container = mkdtempSync(join(tmpdir(), 'inspector-journal-'));
  const channel = join(container, 'Documents/.callkit-simulator');
  mkdirSync(channel, { recursive: true });
  const session = { schemaVersion: 1, bundleID: 'dev.callkitsim.smoke', runID: 'current-run' };
  try {
    writeFileSync(join(channel, 'session.json'), JSON.stringify(session));
    assert.equal(inspectorFixtureJournal(container), join(channel, 'current-run/events.jsonl'));
    for (const invalid of [{ ...session, runID: '../old' }, { ...session, bundleID: 'other' }, { ...session, schemaVersion: 2 }]) {
      writeFileSync(join(channel, 'session.json'), JSON.stringify(invalid));
      assert.throws(() => inspectorFixtureJournal(container), /Invalid Inspector fixture invocation/);
    }
  } finally { rmSync(container, { recursive: true, force: true }); }
});
