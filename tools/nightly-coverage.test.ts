import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const workflow = readFileSync(join(root, '.github/workflows/sdk-m0.yml'), 'utf8');
function required(text: string) {
  const directory = mkdtempSync(join(tmpdir(), 'nightly-coverage-'));
  try {
    const path = join(directory, 'workflow.yml');
    writeFileSync(path, text);
    const source = "import sys,json; sys.path.insert(0,'scripts/ci'); from nightly_coverage import sdk_required; print(json.dumps(sorted(sdk_required(sys.argv[1]))))";
    const result = spawnSync('python3', ['-c', source, path], { cwd: root, encoding: 'utf8', timeout: 10_000 });
    assert.equal(result.status, 0, result.stderr);
    const names: unknown = JSON.parse(result.stdout);
    assert.ok(Array.isArray(names) && names.every(name => typeof name === 'string'));
    return names;
  } finally { rmSync(directory, { recursive: true, force: true }); }
}
test('coverage follows acceptance dependencies and job names', () => {
  const names = required(workflow);
  for (const name of ['apple-host-controls', 'sdk-example', 'sdk-core', 'Call journeys on the simulator']) {
    assert.ok(names.includes(name));
  }
  assert.ok(!names.includes('offline-controls'));
  const changed = workflow.replace('Call journeys on the simulator', 'Renamed native acceptance');
  assert.ok(required(changed).includes('Renamed native acceptance'));
  assert.ok(!required(changed).includes('Call journeys on the simulator'));
  const expanded = workflow.replace('sdk-core, simulator-journeys]', 'sdk-core, simulator-journeys, new-native]') +
    '\n  new-native:\n    runs-on: macos-26\n';
  assert.ok(required(expanded).includes('new-native'));
  assert.throws(() => required(workflow.replace('runs-on: xcode-27', 'runs-on: ${{ matrix.runner }}')));
});
test('unrecognized workflow layout never counts as prior coverage', () => {
  const directory = mkdtempSync(join(tmpdir(), 'nightly-coverage-layout-'));
  try {
    mkdirSync(join(directory, 'scripts/ci'), { recursive: true });
    mkdirSync(join(directory, '.github/workflows'), { recursive: true });
    for (const file of ['nightly_coverage.py', 'changes.py']) {
      copyFileSync(join(root, 'scripts/ci', file), join(directory, 'scripts/ci', file));
    }
    writeFileSync(join(directory, '.github/workflows/sdk-m0.yml'), 'unsupported');
    const source = "import sys; sys.path.insert(0,sys.argv[1]); from nightly_coverage import covered; print(covered('sdk-m0.yml', {'total_count': 0, 'jobs': []}))";
    const result = spawnSync('python3', ['-c', source, join(directory, 'scripts/ci')], { encoding: 'utf8', timeout: 10_000 });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), 'False');
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
